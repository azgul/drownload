require 'awesome_print'

class Log
  def self.v(string)
    print(string)
  end

  def self.d(string)
    print(string.yellow)
  end

  def self.i(string)
    print(string.green)
  end

  def self.w(string)
    print(string.purple)
  end

  def self.e(string)
    print(string.red)
  end

  def self.print(string)
    puts "#{Time.now.strftime('%H:%M:%S')} #{string}"
  end
end