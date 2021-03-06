# coding: utf-8

require 'yaml'
require 'singleton'

module S3FTP

  class App
    include Singleton

    DEFAULT_CONFIG = {
      :user       => nil,
      :group      => nil,
      :bucket     => "my-bucket",
      :aws_key    => "my-key",
      :aws_secret => "super-secret",
      :daemon     => nil,
      :pid_file   => nil
    }

    USAGE =<<-EOS 
failed to download password file from remote bucket. Check that:
    - the correct authentication details are in the config file
    - there is a passwd file in the root of the bucket.

The passwd file should have the following format:
username,password,admin status
james,1234,y
user,3456,n
EOS

    def daemonise!
      return unless @config[:daemon]

      ## close unneeded descriptors,
      $stdin.reopen("/dev/null")
      $stdout.reopen("/dev/null","w")
      $stderr.reopen("/dev/null","w")

      ## drop into the background.
      pid = fork
      if pid
        ## parent: save pid of child, then exit
        if @config[:pid_file]
          File.open(@config[:pid_file], "w") { |io| io.write pid }
        end
        exit!
      end
    end

    def self.run_server(config_path)
      self.instance.run_server(config_path)
    end

    def download_passwd_file(&block)
      on_error = Proc.new { |response|
        $stderr.puts USAGE
        exit(1)
      }
      on_success = Proc.new { |response|
        yield response.response
      }
      item = Happening::S3::Item.new(aws_bucket, 'passwd', :aws_access_key_id => aws_key, :aws_secret_access_key => aws_secret)
      item.get(:on_success => on_success, :on_error => on_error)
    end

    def run_server(config_path)
      update_procline
      load_config(config_path)

      EventMachine.epoll

      EventMachine::run do
        download_passwd_file do |passwd|
          puts "Starting ftp server on 0.0.0.0:21"
          EventMachine::start_server("0.0.0.0", 21, EM::FTPD::Server, S3FTP::Driver, @config, passwd)

          daemonise!
          change_gid
          change_uid
          setup_signal_handlers
        end
      end
    end

    private

    def aws_bucket
      @config[:bucket]
    end

    def aws_key
      @config[:aws_key]
    end

    def aws_secret
      @config[:aws_secret]
    end

    def update_procline
      $0 = "s3ftp"
    end

    def change_gid
      if gid && Process.gid == 0
        Process.gid = gid
      end
    end

    def change_uid
      if uid && Process.euid == 0
        Process::Sys.setuid(uid)
      end
    end

    def setup_signal_handlers
      trap('QUIT') do
        EM.stop
      end
      trap('TERM') do
        EM.stop
      end
      trap('INT') do
        EM.stop
      end
    end

    def load_config(config_path)
      unless File.file?(config_path)
        File.open(config_path,"w") do |io|
          io.write YAML.dump(DEFAULT_CONFIG)
        end
      end
      @config = YAML.load_file(config_path)
    end

    def gid
      return nil if @config[:group].nil?

      begin
        detail = Etc.getpwnam(@config[:group])
        return detail.gid
      rescue
        $stderr.puts "group must be nil or real group" if detail.nil?
      end
    end

    def uid
      return nil if @config[:user].nil?

      begin
        detail = Etc.getpwnam(@config[:user])
        return detail.uid
      rescue
        $stderr.puts "user must be nil a real account" if detail.nil?
      end
    end
  end
end
