require 'net/http'
require 'json'

require 'awesome_print'
require 'childprocess'
require 'mechanize'
require 'streamio-ffmpeg'

require 'log'

class Downloader
  CHANNELS = %w(dr1 dr2 dr3 drk)
  PATH = 'media/siterip/dr.dk'

  def self.check_last_chance
    url = 'http://www.dr.dk/mu-online/api/1.3/list/view/lastchance?limit=10&offset=0&channel='

    CHANNELS.each do |channel|
      json = get_json("#{url}#{channel}")

      if json['Items']
        json['Items'].each do |item|
          download_program_card(item)
        end
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
        ap response.error
    end
  end

  def self.download_program_card(card)
    asset = card['PrimaryAsset'] ? card['PrimaryAsset'] : nil

    if asset.nil?
      Log.e 'No asset for card:'
      ap card
    end

    if 'VideoResource'.eql?(asset['Kind']) && asset['Uri']
      video_json = get_json(asset['Uri'])

      if video_json['Links']
        video_json['Links'].each do |link|
          if 'HLS'.eql?(link['Target'])
            download_video_ffmpeg(card,link['Uri'], card['Slug'])
          end
        end
      else
        Log.w "#{asset['title']} has no links"
      end
    else
      Log.w "#{asset['Title']} has no video resource :("
    end
  end

  def self.download_video_ffmpeg(card, url, filename)
    ffmpeg = "ffmpeg -i #{url} -c copy -bsf:a aac_adtstoasc #{filename}.mp4"

    series = card['SeriesTitle']
    title = card['Title']
    image_url = card['PrimaryImageUri']

    folder = "#{PATH}/#{series}"

    FileUtils.mkdir_p folder

    file_path = "#{folder}/#{filename}"

    if File.exist?("#{file_path}.mp4")
      Log.d "We already have #{filename}.mp4 - skipping"
      return
    end

    Log.d "We're going to download #{filename}"

    dump_json(card, file_path)
    download_image(image_url, file_path)

    command = ['ffmpeg', '-i', url, '-c', 'copy', '-bsf:a', 'aac_adtstoasc', "#{file_path}.mp4"]
    std_output = ''
    std_error = ''

    Open3.popen3(*command) do |stdin, stdout, stderr, wait_thr|
      std_output = stdout.read unless stdout.nil?
      std_error = stderr.read unless stderr.nil?

      exit_status = wait_thr.value

      ap exit_status
    end

    Log.i "We downloaded #{filename}"
  end

  def self.download_image(image_url, file_path)
    Mechanize.new.get(image_url).save("#{file_path}.jpg")
  end

  def self.dump_json(json, filename)
    File.open("#{filename}.json", 'w') { |file| file.write(JSON.pretty_generate(json)) }
  end
end

Downloader.check_last_chance