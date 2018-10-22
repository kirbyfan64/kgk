require "crystagiri"
require "discordcr"
require "logger"
require "openssl"
require "redis"
require "yaml"


class Config
  class Discord
    YAML.mapping(
      client_id: {
        type: UInt64,
        key: "client-id",
      },
      token: String,
    )
  end

  YAML.mapping(
    digest: {
      type: String,
      default: "sha256",
    },
    debug: {
      type: Bool,
      default: false,
    },
    discord: Discord,
    redis: String,
    roles: Array(String),
    prefix: {
      type: String,
      default: ".",
    },
  )
end


class String
  def split_quoted
    results = [] of String
    builder = String::Builder.new
    inside_quote = false

    chars.each do |c|
      if c == ' ' && !inside_quote
        part = builder.to_s
        results.push part if !part.empty?
        builder = String::Builder.new
      elsif c == '"'
        inside_quote = !inside_quote
      else
        builder << c
      end
    end

    remnants = builder.to_s
    results.push remnants if !remnants.empty?

    results
  end

  def digest(name)
    digester = OpenSSL::Digest.new name
    digester << self

    digester.hexdigest
  end
end


class Dispatcher
  @config : Config
  @cache : Discord::Cache
  @redis : Redis

  enum Requires
    AtLeast
    AtMost
    Exactly
  end

  record ImageInfo, url : String, id : String

  def initialize(@bot : Bot, @payload : Discord::Message)
    @config = @bot.config
    @cache = @bot.cache
    @redis = @bot.redis
  end

  def reply(what)
    @bot.reply @payload, what
  end

  def done
    reply "Done!"
  end

  def require_args(command_name, type, requires, args)
    case type
      when Requires::AtLeast
        if args.size < requires
          reply "Command #{command_name} requires at least #{requires} argument(s)."
          return false
        end
      when Requires::AtMost
        if args.size > requires
          reply "Command #{command_name} requires at most #{requires} argument(s)."
          return false
        end
      when Requires::Exactly
        if args.size != requires
          reply "Command #{command_name} requires exactly #{requires} argument(s)."
          return false
        end
    end

    true
  end

  def get_pinterest_image(url)
    html = Crystagiri::HTML.from_url url

    html.css("script") do |tag|
      next unless tag.node["type"]? == "application/json"
      tree = JSON.parse(tag.content)
      page_info = tree["initialPageInfo"]?
      if page_info
        return page_info["meta"]["twitter:image:src"].as_s
      end
    end

    reply "I couldn't find any pictures at that Pinterest URL... :thinking:"
    nil
  end

  def get_image_info(url)
    if url.size > 128
      reply "128-character image? What do you think this is, long-term private storage?!"
      return
    end

    if /^https:\/\/(?:www\.)?pinterest\./ =~ url
      new_url = get_pinterest_image url
      if new_url
        url = new_url
      else
        return
      end
    elsif /^https:\/\/(?:www\.)?google\./ =~ url
      reply "Sorry, I don't think you intended to put a Google search URL. Grab the image itself instead!"
      return
    end

    ImageInfo.new url: url, id: url.digest @config.digest
  end

  def verify_user_permissions
    permitted_roles = @config.roles.map(&.downcase).to_set
    channel = @cache.resolve_channel @payload.channel_id
    member = @cache.resolve_member channel.guild_id.not_nil!, @payload.author.id
    member_roles = member.roles.map{|role_id| @cache.resolve_role(role_id).name.downcase}.to_set

    if (permitted_roles & member_roles).empty?
      reply "Sorry, you don't have permission to do that. :shrug:"
      false
    else
      true
    end
  end

  def verify_tags(tags)
    tags = tags.map &.downcase
    invalid = tags.reject {|tag| /[a-zA-Z0-9_]+$/ =~ tag}
    if !invalid.empty?
      reply "Invalid tags: #{invalid.join(", ")}"
      nil
    else
      tags
    end
  end

  def run_help(command)
    case command
    when "add"
      reply "`.add url tags...` -> Adds an image with the given tags."
    when "remove"
      reply "`.remove url` -> Removes the given image."
    when "image"
      reply "`.image tags...` -> Pick a random image, optionally with the given tags."
    when "tags"
      reply "`.tags` -> List all the current tags."
    when "tag"
      reply "`.tag url tags...` -> Add some tags to an image."
    when "untag"
      reply "`.untag url tags...` -> Remove the tags from the image."
    when "help"
      reply "FOURTH-WALL BREAK"
    when nil
      reply <<-EOF
      Use .help command for help with that command.
      Commands: .add, .remove, .image, .tags, .tag, .untag
      EOF
    else
      reply "Invalid command: #{command} (use .help for a list of commands)"
    end
  end

  def run_add(url, tags)
    tags = verify_tags tags
    return if !verify_user_permissions || !tags

    info = get_image_info url
    return if !info

    @redis.pipelined do |p|
      p.sadd "images", info.id
      p.hset "images:byhash", info.id, info.url

      p.sadd "tags:#{info.id}", tags
      tags.each do |tag|
        p.sadd "tag:#{tag}", info.id
      end
    end

    done
  end

  def run_remove(url)
    return if !verify_user_permissions

    info = get_image_info url
    return if !info

    @redis.watch "tags:#{info.id}"
    tags = @redis.smembers "tags:#{info.id}"

    if tags.empty?
      reply "That image doesn't exist!"
      return
    end

    @redis.multi do |m|
      m.srem "images", info.id
      m.hdel "images:byhash", info.id

      m.del "tags:#{info.id}"
      tags.each do |tag|
        m.srem "tag:#{tag}", info.id
      end
    end

    done
  end

  def run_image(tag)
    if tag
      tags = verify_tags [tag]
      return if !tags
      tag = tags[0]
    end

    set = tag ? "tag:#{tag}" : "images"
    id = @redis.srandmember(set)

    if id
      url = @redis.hget "images:byhash", id.as String
      reply url.not_nil!
    else
      reply "Couldn't find any images...are you sure you have the right tag? :thinking:"
    end
  end

  def run_tags(url)
    tags = if url
      info = get_image_info url
      return if !info
      @redis.smembers("tags:#{info.id}").map{|tag| tag.as(String)}
    else
      @redis.keys("tag:*").map{|tag| tag.as(String).sub "tag:", ""}
    end

    if tags.empty?
      reply "No tags found!"
      return
    end

    tags.sort!

    string = String.build do |str|
      str.puts "```"

      tags.each do |tag|
        str.puts "* #{tag}"
      end

      str.puts "```"
    end
    reply string
  end

  def run_tag(url, tags)
    info = get_image_info url
    return if !info

    if @redis.sismember("images", info.id).zero?
      reply "That image doesn't exist... Add it via .add first! :stuck_out_tongue_closed_eyes:"
      return
    end

    @redis.pipelined do |p|
      p.sadd "tags:#{info.id}", tags
      tags.each do |tag|
        p.sadd "tag:#{tag}", info.id
      end
    end

    done
  end

  def run_untag(url, tags)
    info = get_image_info url
    return if !info

    if @redis.sismember("images", info.id).zero?
      reply "That image doesn't exist... :stuck_out_tongue_closed_eyes:"
      return
    end

    @redis.watch "tags:#{info.id}"

    original_tags = @redis.smembers "tags:#{info.id}"
    if original_tags.size == 1
      reply "You can't take away all the tags from an image!"
      return
    end

    @redis.pipelined do |p|
      p.srem "tags:#{info.id}", tags
      tags.each do |tag|
        p.srem "tag:#{tag}", info.id
      end
    end

    done
  end

  def dispatch
    parts = @payload.content.split_quoted
    if parts.empty?
      reply "Empty command! Use #{@config.prefix}help for help."
      return
    end

    command = parts[0]
    args = parts[1..parts.size]
    case command[1..command.size]
      when "help"
        return if !require_args "help", Requires::AtMost, 2, args
        run_help args[0]?
      when "add"
        return if !require_args "add", Requires::AtLeast, 2, args
        run_add args[0], args[1..args.size]
      when "remove"
        return if !require_args "remove", Requires::Exactly, 1, args
        run_remove args[0]
      when "image"
        return if !require_args "image", Requires::AtMost, 1, args
        run_image args[0]?
      when "tags"
        return if !require_args "tags", Requires::AtMost, 1, args
        run_tags args[0]?
      when "tag"
        return if !require_args "tag", Requires::AtLeast, 2, args
        run_tag args[0], args[1..args.size]
      when "untag"
        return if !require_args "untag", Requires::AtLeast, 2, args
        run_untag args[0], args[1..args.size]
      else
        reply "Invalid command! Use #{@config.prefix}help for help."
    end
  rescue ex
    reply <<-EOF
    *BOOM!!* Sorry, that was the bot shamefully crashing. :frowning:
    After the crying and screaming subsided, this was left behind:
    ```
    #{ex.inspect_with_backtrace}
    ```
    Sorry... :sweat_smile:
    EOF
  end
end


class Bot
  getter config : Config
  getter cache : Discord::Cache
  getter redis : Redis

  def initialize
    @log = Logger.new STDERR, progname: "kgk"

    config_file = ARGV[0]? || "local.yml"

    @config = File.open config_file do |io|
      Config.from_yaml io
    end

    @log.level = Logger::DEBUG if @config.debug

    if @config.redis.starts_with? '$'
      var = @config.redis[1..@config.redis.size]
      @config.redis = ENV[var]
    end

    @redis = Redis.new url: @config.redis

    @discord = Discord::Client.new client_id: @config.discord.client_id,
                                   token: "Bot #{@config.discord.token}",
                                   logger: Logger.new STDERR, level: @log.level
    @cache = Discord::Cache.new(@discord)
    @discord.cache = @cache

    @discord.on_message_create do |payload|
      if payload.content.starts_with? @config.prefix
        dispatcher = Dispatcher.new self, payload
        dispatcher.dispatch
      end
    end
  end

  def reply(reply_to, message)
    @discord.create_message reply_to.channel_id.value, message
  end

  def run
    puts "Running..."
    @discord.run
  end
end


record SavedImageFuture, url : Redis::Future, tags : Redis::Future

def redis_transfer(old_url, new_url)
  old_redis = Redis.new url: old_url
  new_redis = Redis.new url: new_url if new_url

  images = old_redis.smembers "images"
  image_futures = {} of String => SavedImageFuture

  old_redis.pipelined do |p|
    images.each do |image|
      url = p.hget "images:byhash", image
      tags = p.smembers "tags:#{image}"

      image_futures[image.as String] = SavedImageFuture.new url, tags
      # puts "#{image} #{url} #{tags}"
    end
  end

  image_futures.each do |image, future|
    url = future.url.value.as String
    tags = future.tags.value.as Array(Redis::RedisValue)
    puts "WARNING: #{url} has no tags" if tags.empty?
  end

  return if !new_redis

  new_redis.pipelined do |p|
    image_futures.each do |image, future|
      url = future.url.value.as String
      tags = future.tags.value.as Array(Redis::RedisValue)
      next if tags.empty?

        # Re-hash the image ID to sha256 instead of blake2s.
      id = url.digest "sha256"

      p.sadd "images", id
      p.hset "images:byhash", id, url

      p.sadd "tags:#{image}", tags
      tags.each do |tag|
        p.sadd "tag:#{tag}", id
      end
    end
  end
end


if ARGV[0]? == "transfer-db"
  if ARGV.size < 2 || ["-help", "--help", "-h", "help"].includes? ARGV[1]
    puts "usage: kgk transfer-db [old-redis-url] [new-redis-url]"
    exit
  end

  old_redis_url = ARGV[1]
  new_redis_url = ARGV[2]?

  redis_transfer old_redis_url, new_redis_url
  exit
end

bot = Bot.new
bot.run
