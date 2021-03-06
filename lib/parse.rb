require 'couchrest'
require 'yaml'
require 'Dotenv'

Dotenv.load

module AddressParser

	class Address

		@@debug = false

		@@codepoint_db = CouchRest.database!(ENV['CODEPOINT_DB'])
		@@features_db = CouchRest.database!(ENV['FEATURES_DB'])
		@@roads_db = CouchRest.database!(ENV['ROADS_DB'])
		@@ons_db = CouchRest.database!(ENV['ONS_DB'])

		@@counties = {}
		@@features_db.view('counties_latitude/all', { :group => true })['rows'].each do |r|
			@@counties[r['key']] = {}
			@@counties[r['key']][:minLat] = r['value']['min']
			@@counties[r['key']][:maxLat] = r['value']['max']
			@@counties[r['key']][:lat] = r['value']['min'] + (r['value']['max'] - r['value']['min']) / 2
		end
		@@features_db.view('counties_longitude/all', { :group => true })['rows'].each do |r|
			@@counties[r['key']][:minLong] = r['value']['min']
			@@counties[r['key']][:maxLong] = r['value']['max']
			@@counties[r['key']][:long] = r['value']['min'] + (r['value']['max'] - r['value']['min']) / 2
		end

		@@cities = {}
		@@features_db.view('cities/all', { :include_docs => true })['rows'].each do |r|
			r['key'].split(/\s*\/\s*/).each do |name|
				@@cities[name] = r['doc']
				@@cities['Hull'] = r['doc'] if name == 'Kingston upon Hull'
				@@cities['Newcastle'] = r['doc'] if name == 'Newcastle upon Tyne'
			end
		end

		def self.parse(address)
			address.gsub!(/\u2019/,"'")
			parsed = {
				:address => address,
				:remainder => address,
				:errors => [],
				:warnings => [],
				:inferred => {}
			}
			populate_postcode(parsed)
			unless parsed[:postcode] =~ /^BF/
				if parsed[:inferred][:lat]
					populate_road(parsed, exact: true)
					populate_from_list(parsed, :county, @@counties.keys)
					populate_from_list(parsed, :city, @@cities.keys)
					populate_from_area(parsed)
					populate_estate(parsed, :unmatched)
					populate_road(parsed) unless parsed[:street]
					if parsed[:street]
						populate_dependent_street(parsed)
						populate_number(parsed)
					else
						parsed[:errors].push('ERR_NO_STREET')
					end
				else
					populate_from_list(parsed, :county, @@counties.keys)
					populate_from_list(parsed, :city, @@cities.keys)
					populate_from_area(parsed)
					populate_estate(parsed, :unmatched)
					populate_road(parsed)
					if parsed[:street]
						populate_dependent_street(parsed)
						populate_number(parsed)
					else
						parsed[:errors].push('ERR_NO_STREET')
					end
				end
				if parsed[:street] || parsed[:locality] || parsed[:town]
					populate_estate(parsed, :remainder)
					populate_name(parsed)
					populate_floor(parsed)
					populate_flat(parsed)
					populate_lines(parsed)
				else
					parsed[:unmatched] = parsed[:remainder] if parsed[:remainder] != ''
				end
				unless parsed[:city] || parsed[:town] || parsed[:locality]
					parsed[:errors].push('ERR_NO_AREA')
				end
			end
			parsed.delete(:remainder)
			if parsed[:errors].include?('ERR_BAD_POSTCODE') && parsed[:inferred][:minLat]
				infer_postcode(parsed)
			end
			if parsed[:county] && 
				!parsed[:errors].include?('ERR_BAD_POSTCODE') &&
				(!parsed[:inferred][:county] ||
					parsed[:inferred][:county][:full_name] != parsed[:county])
				parsed[:errors].push('ERR_BAD_COUNTY')
			end
			puts parsed.to_yaml if @@debug
			return parsed
		end

		private

		def self.populate_postcode(parsed)
			unless parsed[:postcode]
				m = /^(.+)(,?\s+)([A-Z][A-Z]?[0-9]([A-Z]|[0-9])? [0-9][A-Z][A-Z])$/.match(parsed[:address])
				if m
					parsed[:remainder] = m[1]
					parsed[:postcode] = m[3]
					parsed[:remainder].gsub!(/(\s*,\s*|,?\s+)$/, '')
				end
			end
			if parsed[:postcode] =~ /^BF/
				parsed[:name] = 'BFPO'
				m = /BFPO ([0-9]+)/.match(parsed[:address])
				parsed[:number] = m[1] if m
			else
				begin
					codepoint = @@codepoint_db.get(parsed[:postcode])
					parsed[:inferred][:lat] = codepoint['Location']['latitude']
					parsed[:inferred][:long] = codepoint['Location']['longitude']
					parsed[:inferred][:latlong_source] = :postcode
					parsed[:inferred][:pqi] = codepoint['Positional_quality_indicator'].to_i
					parsed[:inferred][:county] = hash(@@ons_db.get(codepoint['Admin_county_code'])) unless codepoint['Admin_county_code'] == ''
					parsed[:inferred][:district] = hash(@@ons_db.get(codepoint['Admin_district_code']))
					parsed[:inferred][:ward] = hash(@@ons_db.get(codepoint['Admin_ward_code']))
					parsed[:inferred][:regional_health_authority] = hash(@@ons_db.get(codepoint['NHS_regional_HA_code'])) unless codepoint['NHS_regional_HA_code'] == ''
					parsed[:inferred][:health_authority] = hash(@@ons_db.get(codepoint['NHS_HA_code'])) unless codepoint['NHS_HA_code'] == ''
				rescue RestClient::ResourceNotFound
					# no such postcode
					parsed[:errors].push('ERR_BAD_POSTCODE')
				end
			end
			return parsed
		end

		def self.populate_from_list(parsed, property, list, exact: false)
			# debugging stuff
			unless !@@debug || [:city,:county].include?(property)
				puts "#{property.to_s} in #{parsed[parsed[:street] ? :unmatched : :remainder]}#{exact ? ' (exact)' : ''}"
				puts list.inspect
			end

			if parsed[:county] && 
				 [:city,:town].include?(property) && 
				 list.map { |i| i.upcase }.include?(parsed[:county].upcase)
				# what's been identified as a county is actually a city
				parsed[property] = parsed[:county]
				parsed.delete(:county)
			elsif !list.empty?
				remainder = parsed[parsed[:street] ? :unmatched : :remainder]

				# find all the matches
				matches = []
				list.each do |item|
					m = Regexp.new("^(.+(\s+|,\s*))?#{property == :street ? '' : '?'}(#{item.gsub(/(\(|\)|\\)/, '\\\\\1')})(,\s*.+)?$", Regexp::IGNORECASE).match(remainder)
					matches.push(m) if m
				end

				# couldn't find a matching street? what about one that's named something similar?
				originals = {}
				if matches.empty? && property == :street && !exact
					list.each do |item|
						words = item.gsub(/(\p{Punct})/, '\1?').gsub(/(\(|\)|\\)/, '\\\\\1').split(' ')
						words.map!.with_index do |word,i| 
							i > 0 ? "(?:#{word})?" : word 
						end
						regexp = Regexp.new("^(.+(\s+|,\s*))??(#{words.join(' ?')}[^, ]*)(,\s*.+)?$", Regexp::IGNORECASE)
						m = regexp.match(remainder)
						if m && m[3] != ''
							matches.push(m)
							originals[m[3]] = [] unless originals[m[3]]
							originals[m[3]].push(item)
						end
					end
				end

				# select the one that starts earliest and is longest
				matches.sort_by! { |m| [m[1] ? m[1].length : 0, m[3].length] }
				m = matches[0]
				if m
					parsed[parsed[:street] ? :unmatched : :remainder] = m[1] ? m[1].gsub!(/(,\s*|\s+)$/, '') : ''
					parsed[property] = m[3]
					if originals[m[3]]
						originals[m[3]].sort_by! { |s| 
							lev(s.upcase, m[3].upcase)
						}
						parsed[:inferred][property] = originals[m[3]][0]
						parsed[:errors].push("ERR_BAD_#{property.to_s.upcase}")
					end
					unless parsed[:inferred][:lat] && parsed[:inferred][:latlong_source] == :postcode
						if property == :city
							city = @@cities[parsed[:city]]
							parsed[:inferred][:lat] = city['Location']['latitude']
							parsed[:inferred][:long] = city['Location']['longitude']
							parsed[:inferred][:latlong_source] = :city
							parsed[:inferred][:county] = { :full_name => city['FULL_COUNTY'] }
						elsif property == :county
							county = @@counties[parsed[:county]]
							parsed[:inferred][:lat] = county[:lat]
							parsed[:inferred][:long] = county[:long]
							parsed[:inferred][:minLat] = county[:minLat]
							parsed[:inferred][:maxLat] = county[:maxLat]
							parsed[:inferred][:minLong] = county[:minLong]
							parsed[:inferred][:maxLong] = county[:maxLong]
							parsed[:inferred][:latlong_source] = :county
						end
					end
					if m[4]
						parsed[:unmatched] = '' unless parsed[:unmatched]
						parsed[:unmatched] += m[4].gsub!(/^(,\s*|\s+)/, '')
						unless parsed[:street]
							parsed[:warnings].push('WARN_UNKNOWN_AREA')
						end
					end
				end
			end
			return parsed
		end

		def self.populate_areas(parsed, features)
			if parsed[:inferred][:lat]
				features.sort_by! { |feature|
					x = feature['doc']['Location']['latitude'].to_f - parsed[:inferred][:lat].to_f
					y = feature['doc']['Location']['longitude'].to_f - parsed[:inferred][:long].to_f
					x * x + y * y
				}.reverse!
			end

			towns = {}
			localities = {}
			features.each do |feature|
				if feature['doc']['F_CODE'] == 'T'
					feature['doc']['DEF_NAM'].split('/').each do |t|
						towns[t.upcase] = feature['doc']
					end
				elsif feature['doc']['F_CODE'] == 'O'
					feature['doc']['DEF_NAM'].split('/').each do |t|
						localities[t.upcase] = feature['doc']
					end
				end
			end

			populate_from_list(parsed, :town, towns.keys)

			# if we've found a town, remove localities that aren't in the same county as the town
			# otherwise you get localities from completely different parts of the country
			if parsed[:town]
				town = towns[parsed[:town].upcase]
				localities.delete_if do |name,locality|
					locality['FULL_COUNTY'] != town['FULL_COUNTY']
				end
			end
			populate_from_list(parsed, :locality, localities.keys)

			# fixing it when the locality is a locality within a town
			if parsed[:town] && !parsed[:locality] && parsed[parsed[:street] ? :unmatched : :remainder]
				unmatched = parsed[parsed[:street] ? :unmatched : :remainder]
				parsed[parsed[:street] ? :unmatched : :remainder] += " #{parsed[:town]}"
				populate_from_list(parsed, :locality, localities.keys)
				if parsed[:locality]
					parsed.delete(:town)
				else
					parsed[parsed[:street] ? :unmatched : :remainder] = unmatched
				end
			end

			unless parsed[:inferred][:lat] && [:postcode,:street].include?(parsed[:inferred][:latlong_source])
				if parsed[:locality]
					locality = localities[parsed[:locality].upcase]
					parsed[:inferred][:lat] = locality['Location']['latitude']
					parsed[:inferred][:long] = locality['Location']['longitude']
					parsed[:inferred][:latlong_source] = :locality
					parsed[:inferred][:county] = { :full_name => locality['FULL_COUNTY'] }
				elsif parsed[:town]
					town = towns[parsed[:town].upcase]
					parsed[:inferred][:lat] = town['Location']['latitude']
					parsed[:inferred][:long] = town['Location']['longitude']
					parsed[:inferred][:latlong_source] = :town
					parsed[:inferred][:county] = { :full_name => town['FULL_COUNTY'] }
				end
			end
		end

		def self.populate_from_area(parsed)
			if parsed[:inferred][:lat] && parsed[:inferred][:latlong_source] != :county
				location = [parsed[:inferred][:lat], parsed[:inferred][:long]]
				latfuzz = parsed[:inferred][:pqi] ? parsed[:inferred][:pqi].to_f / 60 : 0.2
				longfuzz = parsed[:inferred][:pqi] ? parsed[:inferred][:pqi].to_f / 60 : 0.4
				startkey = [location[0] - latfuzz, location[1] - latfuzz]
				endkey = [location[0] + longfuzz, location[1] + longfuzz]
				inlat = @@features_db.view('localities_by_location/all', {:startkey => startkey, :endkey => endkey})
				inlatlong = []
				inlat['rows'].each do |f|
					inlatlong.push(f['id']) if f['key'][1] >= startkey[1] && f['key'][1] < endkey[1]
				end
				features = @@features_db.get_bulk(inlatlong)['rows']
			elsif parsed[:county]
				features = @@features_db.view('localities_by_county/all', {:key => parsed[:county], :include_docs => true})['rows']
			end
			if features
				populate_areas(parsed, features)
				unless parsed[:locality] || parsed[:town]
					features = @@features_db.view('features_by_name/all', {:keys => parsed[:remainder].split(/\s*,\s*/), :include_docs => true})['rows']
					populate_areas(parsed, features)
					parsed[:errors].push('ERR_BAD_COUNTY') if parsed[:county] && (parsed[:locality] || parsed[:town])
				end
			end
		end

		def self.populate_estate(parsed, property)
			m = /^(.+,\s+)?((([A-Z]?[0-9][-\.0-9a-zA-Z]*)\s+)?([^,]+\s(Business Park|Industrial Estate|Industrial Park)))$/.match(parsed[property])
			if m
				parsed[property] = m[1] ? m[1].gsub!(/(\s*,\s*|,?\s+)$/, '') : ''
				parsed[:number] = m[4] if m[4]
				parsed[:estate] = m[5]
				parsed[:warnings].push('WARN_GUESSED_ESTATE')
			end
			return parsed
		end

		def self.populate_road(parsed, exact: false)
			if parsed[:inferred][:latlong_source] == :postcode
				minLat = (parsed[:inferred][:lat] / ENV['PIN_LAT'].to_f).floor
				maxLat = (parsed[:inferred][:lat] / ENV['PIN_LAT'].to_f).ceil
				minLong = (parsed[:inferred][:long] / ENV['PIN_LONG'].to_f).floor
				maxLong = (parsed[:inferred][:long] / ENV['PIN_LONG'].to_f).ceil
				keys = [
					[minLat,minLong],
					[minLat,maxLong],
					[maxLat,minLong],
					[maxLat,maxLong]
				]
				parsed = get_roads(parsed, keys, exact)
				unless parsed[:street]
					keys = [
						[minLat-1,minLong],
						[minLat-1,maxLong],
						[minLat,minLong-1],
						[minLat,maxLong+1],
						[maxLat+1,minLong],
						[maxLat+1,maxLong],
						[maxLat,minLong-1],
						[maxLat,maxLong+1]
					]
					parsed = get_roads(parsed, keys, exact)
					unless parsed[:street] || exact
						parsed = guess_road(parsed)
					end
				end
			else
				parsed = guess_road(parsed)
			end
			return parsed
		end

		def self.guess_road(parsed)
			roads = []
			# look for something that looks like a street name preceded by a number
			m = /([0-9]+[^ ]*)? ([^,]+)$/.match(parsed[:remainder])
			if m
				road = m[2]
				roads = @@roads_db.view('roads_by_name/all', {:key => road.upcase, :include_docs => true})['rows']
			end
			if roads.empty?
				# ok, so maybe we've got a building name followed by a street
				m = /([^ ]+) (.+)$/.match(road)
				if m
					road = m[2]
					roads = @@roads_db.view('roads_by_name/all', {:key => road.upcase, :include_docs => true})['rows']
				elsif parsed[:locality]
					# maybe what we've recognised as a locality is actually a street
					m = /([0-9]+[^ ]*)? ([^,]+)$/.match("#{parsed[:remainder]}, #{parsed[:locality]}")
					if m
						road = m[2]
						roads = @@roads_db.view('roads_by_name/all', {:key => road.upcase, :include_docs => true})['rows']
						unless roads.empty?
							parsed[:remainder] = "#{parsed[:remainder]}, #{parsed[:locality]}"
							parsed.delete(:locality)
						end
					else
						roads = []
					end
				end
			end
			roads.sort_by! { |row|
				x = row['doc']['Centre']['latitude'].to_f - parsed[:inferred][:lat].to_f
				y = row['doc']['Centre']['longitude'].to_f - parsed[:inferred][:long].to_f
				x * x + y * y
			}
			unless roads.empty?
				road = roads[0]['doc']
				populate_from_list(parsed, :street, [road['Name']])
				if parsed[:inferred][:latlong_source] == :postcode
					# we should have been able to pick up a street without guessing
					# so if we get a street like this, it's a bad one
					parsed[:errors].push('ERR_BAD_STREET')
				else
					parsed[:inferred][:lat] = road['Centre']['latitude']
					parsed[:inferred][:long] = road['Centre']['longitude']
					parsed[:inferred][:minLat] = road['Min']['latitude']
					parsed[:inferred][:maxLat] = road['Max']['latitude']
					parsed[:inferred][:minLong] = road['Min']['longitude']
					parsed[:inferred][:maxLong] = road['Max']['longitude']
					parsed[:inferred][:latlong_source] = :street
				end
			end
			return parsed
		end

		def self.get_roads(parsed, keys, exact)
			roads = {}
			@@roads_db.view('roads_by_location/all', { :keys => keys, :include_docs => true })['rows'].each do |road|
				roads[road['doc']['Name']] = road['doc'] if road['doc']['Name']
			end
			populate_from_list(parsed, :street, roads.keys, exact: exact)
			if parsed[:street]
				road = roads[parsed[:inferred][:street] || parsed[:street].upcase]
				parsed[:inferred][:minLat] = road['Min']['latitude']
				parsed[:inferred][:maxLat] = road['Max']['latitude']
				parsed[:inferred][:minLong] = road['Min']['longitude']
				parsed[:inferred][:maxLong] = road['Max']['longitude']
			end
			return parsed
		end

		def self.populate_dependent_street(parsed)
			m = /^([^ ]+,?\s+)([^ ,]+(\s[^ ,]+)*\s(Road|Street|Hill|Avenue|Mews|Park|Parade|Square|Court))$/.match(parsed[:remainder])
			if m
				parsed[:remainder] = m[1] || ''
				parsed[:dependent_street] = m[2]
				parsed[:remainder].gsub!(/(\s*,\s*|,?\s+)$/, '')
				parsed[:warnings].push('WARN_GUESSED_DEPENDENT_STREET')
			end
			return parsed
		end

		def self.populate_number(parsed)
			m = /^(.+(\s|,))?([0-9]+[a-zA-Z]*(-[0-9]+[a-zA-Z]*)?)$/.match(parsed[:remainder])
			if m
				parsed[:remainder] = m[1] || ''
				parsed[:number] = m[3]
				parsed[:remainder].gsub!(/(\s*,\s*|,?\s+)$/, '')
			end
			return parsed
		end

		def self.populate_name(parsed)
			m = /^(.+,\s*)?([^,]+)$/.match(parsed[:remainder])
			if m && !(/\b(floor|flat|unit)\b/i =~ m[2])
				if m[2] =~ /\s(&|and)\s/
					parsed[:name] = parsed[:remainder]
					parsed[:remainder] = ''
				else
					n = /^([^ ]?[0-9][^ ]*) (.+ .+)$/.match(m[2])
					parsed[:remainder] = m[1] || ''
					parsed[:remainder] += n[1] if n
					parsed[:remainder].gsub!(/(\s*,\s*|,?\s+)$/, '')
					parsed[:name] = n ? n[2] : m[2]
				end
			end
			return parsed
		end

		def self.populate_floor(parsed)
			m = /^(.+(\s|,))?([0-9]+[a-zA-Z]* Fl(oo)?r|Fl(oo)?r [0-9]+[a-zA-Z]*)$/i.match(parsed[:remainder])
			if m
				parsed[:remainder] = m[1] || ''
				parsed[:remainder].gsub!(/(\s*,\s*|,?\s+)$/, '')
				parsed[:floor] = m[3]
			end
			return parsed
		end

		def self.populate_flat(parsed)
			m = /^(.+(\s|,))??(([^,]+ )?(Flat|Unit)( [^,]+)?|[-0-9\.]+)$/i.match(parsed[:remainder])
			if m
				parsed[:remainder] = m[1] || ''
				parsed[:remainder].gsub!(/(\s*,\s*|,?\s+)$/, '')
				parsed[:flat] = m[3]
			end
			return parsed
		end

		def self.populate_lines(parsed)
			m = /^(.+\s(&|and)\s[^,]+)(.*)$/.match(parsed[:remainder])
			if m
				parsed[:lines] = [] unless parsed[:lines]
				parsed[:lines].push(m[1])
				parsed[:remainder] = m[3].gsub(/^,\s*/, '') || ''
				populate_lines(parsed) unless parsed[:remainder] == ''
			elsif parsed[:remainder] != ''
				parsed[:lines] = [] unless parsed[:lines]
				parsed[:remainder].split(',').each do |l|
					parsed[:lines].push(l.gsub(/(^\s+)|(\s+$)/, ''))
				end
			end
			return parsed
		end

		def self.infer_postcode(parsed)
			minLat = (parsed[:inferred][:minLat].to_f / ENV['PIN_LAT'].to_f).floor
			maxLat = (parsed[:inferred][:maxLat].to_f / ENV['PIN_LAT'].to_f).ceil
			minLong = (parsed[:inferred][:minLong].to_f / ENV['PIN_LONG'].to_f).floor
			maxLong = (parsed[:inferred][:maxLong].to_f / ENV['PIN_LONG'].to_f).ceil
			keys = []
			(minLat..maxLat).each do |lat|
				(minLong..maxLong).each do |long|
					keys.push([lat,long])
				end
			end
			postcodes = @@codepoint_db.view('postcodes_by_location/all', { :keys => keys, :include_docs => true })['rows']
			postcodes.sort_by! { |row|
				x = row['doc']['Location']['latitude'].to_f - parsed[:inferred][:lat].to_f
				y = row['doc']['Location']['longitude'].to_f - parsed[:inferred][:long].to_f
				x * x + y * y
			}
			unless postcodes.empty?
				parsed[:inferred][:postcodes] = postcodes.map { |postcode| postcode['doc']['Postcode'] }.uniq
			end
			return parsed
		end

		def self.hash(doc)
			hash = {}
			doc.each do |key,value|
				hash[key.to_sym] = value unless key == '_rev'
			end
			return hash
		end

		def self.lev(s, t)
		  m = s.length
		  n = t.length
		  return m if n == 0
		  return n if m == 0
		  d = Array.new(m+1) {Array.new(n+1)}

		  (0..m).each {|i| d[i][0] = i}
		  (0..n).each {|j| d[0][j] = j}
		  (1..n).each do |j|
		    (1..m).each do |i|
		      d[i][j] = if s[i-1] == t[j-1]  # adjust index into string
		                  d[i-1][j-1]       # no operation required
		                else
		                  [ d[i-1][j]+1,    # deletion
		                    d[i][j-1]+1,    # insertion
		                    d[i-1][j-1]+1,  # substitution
		                  ].min
		                end
		    end
		  end
		  d[m][n]
 		end

	end

end
