# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/timestamp"
require "stud/interval"
require "socket" # for Socket.gethostname

# Read mails from IMAP server
#
# Periodically scan an IMAP folder (`INBOX` by default) and move any read messages
# to the trash.
class LogStash::Inputs::IMAP < LogStash::Inputs::Base
  config_name "imap"

  default :codec, "plain"

  config :host, :validate => :string, :required => true
  config :port, :validate => :number

  config :user, :validate => :string, :required => true
  config :password, :validate => :password, :required => true
  config :secure, :validate => :boolean, :default => true
  config :verify_cert, :validate => :boolean, :default => true

  config :folder, :validate => :string, :default => 'INBOX'
  config :fetch_count, :validate => :number, :default => 50
  config :lowercase_headers, :validate => :boolean, :default => true
  config :check_interval, :validate => :number, :default => 300
  config :delete, :validate => :boolean, :default => false

  # For multipart messages, use the first part that has this
  # content-type as the event message.
  config :content_type, :validate => :string, :default => "text/plain"

  def register
    require "net/imap" # in stdlib
    require "mail" # gem 'mail'

    if @secure and not @verify_cert
      @logger.warn("Running IMAP without verifying the certificate may grant attackers unauthorized access to your mailbox or data")
    end

    if @port.nil?
      if @secure
        @port = 993
      else
        @port = 143
      end
    end

    @content_type_re = Regexp.new("^" + @content_type)
  end # def register

  def connect
    sslopt = @secure
    if @secure and not @verify_cert
        sslopt = { :verify_mode => OpenSSL::SSL::VERIFY_NONE }
    end
    imap = Net::IMAP.new(@host, :port => @port, :ssl => sslopt)
    imap.login(@user, @password.value)
    return imap
  end

  def run(queue)
    @run_thread = Thread.current
    Stud.interval(@check_interval) do
      check_mail(queue)
    end
  end

  def check_mail(queue)
    # TODO(sissel): handle exceptions happening during runtime:
    # EOFError, OpenSSL::SSL::SSLError
    imap = connect
    imap.select(@folder)
    ids = imap.search("NOT SEEN")

    ids.each_slice(@fetch_count) do |id_set|
      items = imap.fetch(id_set, "RFC822")
      items.each do |item|
        next unless item.attr.has_key?("RFC822")
        mail = Mail.read_from_string(item.attr["RFC822"])
        queue << parse_mail(mail)
      end

      imap.store(id_set, '+FLAGS', @delete ? :Deleted : :Seen)
    end

    imap.close
    imap.disconnect
  end

  def parse_mail(mail)
    # Add a debug message so we can track what message might cause an error later
    @logger.debug? && @logger.debug("Working with message_id", :message_id => mail.message_id)
    # TODO(sissel): What should a multipart message look like as an event?
    # For now, just take the plain-text part and set it as the message.
    if mail.parts.count == 0
      # No multipart message, just use the body as the event text
      message = mail.body.decoded
    else
      # Multipart message; use the first text/plain part we find
      part = mail.parts.find { |p| p.content_type.match @content_type_re } || mail.parts.first
      if part.content_type.start_with?('multipart/related')
        part = part.parts.find { |p| p.content_type.match @content_type_re } || part.parts.first
      end
      if part.content_type.start_with?('multipart/alternative')
        part = part.text_part
      end
      message = part.decoded
    end

    @codec.decode(message) do |event|
      # Use the 'Date' field as the timestamp
      event.timestamp = LogStash::Timestamp.new(mail.date.to_time)

      # Add fields: Add message.header_fields { |h| h.name=> h.value }
      mail.header_fields.each do |header|
        # 'header.name' can sometimes be a Mail::Multibyte::Chars, get it in String form
        name = @lowercase_headers ? header.name.to_s.downcase : header.name.to_s
        # Call .decoded on the header in case it's in encoded-word form.
        # Details at:
        #   https://github.com/mikel/mail/blob/master/README.md#encodings
        #   http://tools.ietf.org/html/rfc2047#section-2
        value = transcode_to_utf8(header.decoded.to_s)

        # Assume we already processed the 'date' above.
        next if name == "Date"

        case (field = event[name])
        when String
          # promote string to array if a header appears multiple times
          # (like 'received')
          event[name] = [field, value]
        when Array
          field << value
          event[name] = field
        when nil
          event[name] = value
        end
      end

      decorate(event)
      event
    end
  end

  def stop
    Stud.stop!(@run_thread)
    $stdin.close
  end

  private

  # transcode_to_utf8 is meant for headers transcoding.
  # the mail gem will set the correct encoding on header strings decoding
  # and we want to transcode it to utf8
  def transcode_to_utf8(s)
    unless s.nil?
      s.encode(Encoding::UTF_8, :invalid => :replace, :undef => :replace)
    end
  end
end
