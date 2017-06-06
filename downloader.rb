require 'net/http'
require 'json'

require 'awesome_print'
require 'childprocess'
require 'm3u8'
require 'mechanize'
require 'streamio-ffmpeg'

require_relative 'log'

class Downloader
  CHANNELS = %w(dr1 dr2 dr3 drk)
  LIMIT = 50

  PATH = "#{File.expand_path('~')}/media/siterip/dr.dk"

  def self.check_last_chance
    url = "https://www.dr.dk/mu-online/api/1.3/list/view/lastchance?limit=#{LIMIT}&offset=0&channel="

    CHANNELS.each do |channel|
      json = get_json("#{url}#{channel}")
      parse_items(json)

      while json['Paging'] && json['Paging']['Next']
        json = get_json(json['Paging']['Next'])
        parse_items(json)
      end
    end
  end

  def self.parse_items(json)
    if json['Items']
      json['Items'].each do |item|
        download_program_card(item)
      end
    end
  end

  def self.get_json(url, limit = 10)
    raise ArgumentError, 'HTTP redirect too deep' if limit == 0

    uri = URI(url)
    response = Net::HTTP.get_response(uri)

    case response
      when Net::HTTPSuccess     then JSON.parse(response.body)
      when Net::HTTPRedirection then get_json(response['location'], limit - 1)
      else
        Log.e "Error occurred while getting json for #{url}"
        ap response.error!
    end
  end


  def self.http_get(url, limit = 10)
    raise ArgumentError, 'HTTP redirect too deep' if limit == 0

    uri = URI(url)
    response = Net::HTTP.get_response(uri)

    case response
      when Net::HTTPSuccess     then response
      when Net::HTTPRedirection then http_get(response['location'], limit - 1)
      else
        Log.e "Error occurred while getting json for #{url}"
        ap response.error!
    end
  end

  def self.download_program_card(card)
    asset = card['PrimaryAsset'] ? card['PrimaryAsset'] : nil

    if asset.nil?
      Log.e 'No asset for card:'
      ap card
    end

    channel = card['PrimaryChannelSlug']
    series = card['SeriesSlug']
    season = card['SeasonSlug']
    folder = "#{PATH}/#{channel}/#{series}/#{season}"
    filename = card['Slug']

    file_path = "#{folder}/#{filename}"

    if File.exist? "#{file_path}.mp4"
      Log.d "We already have #{filename}.mp4 - skipping"
      return
    end

    if 'VideoResource'.eql?(asset['Kind']) && asset['Uri']
      video_json = get_json(asset['Uri'])

      if asset['Downloadable']
        download_highest_bitrate_video(card, video_json, filename)
      elsif video_json['Links']
        video_json['Links'].each do |link|
          if 'HLS'.eql?(link['Target'])
            download_video_ffmpeg(card,link['Uri'], filename)
          end
        end
      else
        Log.w "#{asset['title']} has no links"
      end
    else
      Log.w "#{asset['Title']} has no video resource :("
    end
  end

  def self.download_highest_bitrate_video(card, video_json, filename)
    channel = card['PrimaryChannelSlug']
    series = card['SeriesSlug']
    season = card['SeasonSlug']
    folder = "#{PATH}/#{channel}/#{series}/#{season}"
    file_path = "#{folder}/#{filename}"
    FileUtils.mkdir_p folder

    if File.exist?("#{file_path}.mp4")
      Log.d "We already have #{filename}.mp4 - skipping"
      return
    end

    Log.d "We're going to find the best bitrate we can for #{filename}"

    candidate = nil

    video_json['Links'].each do |link|
      if 'Download'.eql?(link['Target'])
        if candidate.nil?
          candidate = link
        else
          candidate = link if link['Bitrate'] > candidate['Bitrate']
        end
      end
    end

    if candidate.nil?
      Log.e "Expected no downloadable target for #{filename}"
      ap video_json
    else
      Log.d "Highest bitrate found: #{candidate['Bitrate']}"
      download_video_ffmpeg(card, candidate['Uri'], filename)
    end
  end

  def self.download_video_ffmpeg(card, url, filename, force = false)
    if url.include?('master.m3u8')
      return download_video_ffmpeg(card, parse_m3u8(url), filename)
    end

    channel = card['PrimaryChannelSlug']
    series = card['SeriesSlug']
    season = card['SeasonSlug']
    folder = "#{PATH}/#{channel}/#{series}/#{season}"

    FileUtils.mkdir_p folder

    file_path = "#{folder}/#{filename}"

    if File.exist? "#{file_path}.mp4"
      if force
        FileUtils.rm "#{file_path}.mp4"
      else
        Log.d "We already have #{filename}.mp4 - skipping"
        return
      end
    end

    Log.d "We're going to download #{filename} with ffmpeg"
    Log.d "Url: #{url}"

    save_metadata(card, file_path)

    command = ['ffmpeg', '-headers', "'User-Agent: linux'$'\r\n'", '-i', url, '-c', 'copy', '-bsf:a', 'aac_adtstoasc', "#{file_path}.mp4"]
    #command = "ffmpeg -headers 'User-Agent: linux'$'\r\n' -i #{url} -c copy -bsf:a aac_adtstoasc #{file_path}.mp4"
    #`#{command}`
    std_output = ''
    std_error = ''

    Open3.popen3(*command) do |stdin, stdout, stderr, wait_thr|
      std_output = stdout.read unless stdout.nil?
      std_error = stderr.read unless stderr.nil?
    end

    Log.i "Downloaded #{file_path}.mp4"
  end

  def self.parse_m3u8(url)
    response = http_get(url)

    playlist = M3u8::Playlist.read(response.body)

    candidate = nil

    playlist.items.each do |item|
      if !item.is_a?(M3u8::MediaItem) && candidate.nil?
        candidate = item
      elsif item.is_a?(M3u8::PlaylistItem) && item.bandwidth > candidate.bandwidth
        candidate = item
      end

    end

    candidate.uri
  end

  def self.save_metadata(card, file_path)
    dump_json(card, file_path)
    download_image(card['PrimaryImageUri'], file_path)
  end

  def self.download_image(image_url, file_path, retries = 10)
    if retries == 0
      Log.e "failed to download #{image_url} after 10 retries, giving up :-("
      return
    end

    begin
      Mechanize.new.get(image_url).save!("#{file_path}.jpg")
    rescue
      download_image(image_url, file_path)
    end
  end

  def self.dump_json(json, filename)
    File.open("#{filename}.json", 'w') { |file| file.write(JSON.pretty_generate(json)) }
  end
end

Downloader.check_last_chance
