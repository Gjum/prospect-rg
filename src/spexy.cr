require "rosegold"
require "socket"

include Rosegold

class Prospect::Server
  getter bot : Client
  getter host : String, port : UInt16
  getter protocol_version = 758_u32
  private getter clients = Array(ServerClient).new
  private getter clients_mutex : Mutex = Mutex.new
  getter captures : Captures
  @listener : Fiber

  def initialize(@bot : Client, @host : String = "localhost", @port : UInt16 = 25565)
    if host.includes? ":"
      @host, port_str = host.split ":"
      @port = port_str.to_u16
    end
    @server = TCPServer.new(@host, @port)
    @captures = Captures.new @bot

    @bot.on Event::RawPacket do |raw_packet|
      @captures.handle_raw_packet raw_packet.bytes
      clients_mutex.synchronize do
        clients.each &.handle_raw_bot_packet raw_packet.bytes
      end
    end

    @bot.on Clientbound::DestroyEntities do |packet|
      @captures.handle_destroy_entities packet.entity_ids
    end

    respawning = false
    @bot.on Clientbound::Respawn do |packet|
      clients_mutex.synchronize do
        clients.each &.handle_respawn packet
      end
      respawning = true # forward next position reset
    end

    @bot.on Clientbound::PlayerPositionAndLook do |packet|
      if respawning
        clients_mutex.synchronize do
          clients.each &.send_packet packet
        end
        respawning = false
      end
    end

    @bot.on Event::Disconnected do |reason|
      # spectators may stay in the world
      packet = Clientbound::ChatMessage.new \
        Rosegold::Chat.new "Disconnected: #{reason}"
      clients_mutex.synchronize do
        clients.each &.send_packet packet
      end
    end

    @bot.on Event::PhysicsTick do
      clients_mutex.synchronize do
        clients.each &.handle_physics_tick
      end
    end

    # @bot.on Event::SlotChange do |slot_change|
    #   clients_mutex.synchronize do
    #     clients.each &.handle_slot_change
    #   end
    # end

    @listener = spawn do
      while socket = @server.accept?
        spawn handle_client(socket)
      end
    end
  end

  def close
    clients_mutex.synchronize do
      clients.each do |client|
        spawn client.kick Chat.new "Server closed"
      end
    end
    @server.close
  end

  private def handle_client(socket : TCPSocket)
    Log.info { "Client connected from #{socket.remote_address}" }

    # peek_bytes = socket.peek || [] of UInt8
    # if peek_bytes[0]? == 0xFE_u8
    #   Log.debug { "Legacy ping: #{peek_bytes}" }
    #   server = TCPSocket.new(host, port)
    #   IO.copy socket, server
    #   IO.copy server, socket
    #   server.skip_to_end
    #   server.close
    #   return
    # end

    io = Minecraft::IO::Wrap.new socket
    connection = Connection::Server.new io, ProtocolState::HANDSHAKING.serverbound

    handshake = connection.read_packet
    unless handshake.is_a? Serverbound::Handshake
      raise "Invalid spectator handshake: got #{handshake}"
    end
    case handshake.next_state
    when 1 # status
      handle_status connection
    when 2 # login
      handle_login connection, handshake
    else
      raise "Invalid spectator handshake: next_state=#{handshake.next_state}"
    end
  rescue ex
    Log.warn { "During handle_client: #{ex}\n#{ex.backtrace.join "\n"}" }
    socket.close
  end

  private def handle_status(connection : Connection::Server)
    connection.state = ProtocolState::STATUS.serverbound
    loop do
      packet = connection.read_packet
      case packet
      when .is_a? Serverbound::StatusRequest
        status = Client.status @bot.host, @bot.port
        Log.debug { "Forwarding server status: #{status}" }
        connection.send_packet status
      when .is_a? Serverbound::StatusPing
        connection.send_packet Clientbound::StatusPong.new packet.ping_id
        connection.disconnect Chat.new "Finished status sequence"
        return
      else raise "Invalid spectator status sequence: got #{packet}"
      end
    end
  end

  private def handle_login(connection : Connection::Server, handshake : Serverbound::Handshake)
    unless handshake.protocol_version == self.protocol_version
      raise "Unsupported spectator protocol version #{handshake.protocol_version}"
    end
    connection.state = ProtocolState::LOGIN.serverbound
    client = ServerClient.new @bot, connection, self
    connection.handler = client
    clients_mutex.synchronize do
      clients << client
    end
    begin
      client.run
    rescue ex
      Log.warn { "During client handler: #{ex}\n#{ex.backtrace.join "\n"}" }
      client.kick Chat.new "Internal error: #{ex}"
    end
    clients_mutex.synchronize do
      clients.delete client
    end
  end
end

class Prospect::ServerClient < Rosegold::EventEmitter
  getter bot : Client
  getter connection : Connection::Server
  getter username = "?"
  getter uuid = UUID.empty
  property? joined = false
  property entity_id : Int32 = -1
  property gamemode : Int8 = 1
  property? forward_chat = true
  property? forward_place_block = true

  def initialize(@bot, @connection, @server : Prospect::Server); end

  delegate read_packet, send_packet, to: @connection
  delegate captures, to: @server

  def run
    login_start = connection.read_packet
    unless login_start.is_a? Serverbound::LoginStart
      raise "Invalid spectator login start: got #{login_start}"
    end
    handle_login_start login_start.username

    loop do
      if connection.close_reason
        Fiber.yield
        Log.info { "[#{username}] Spectator disconnected: #{connection.close_reason}" }
        break
      end
      packet = read_packet
      # make sure all packets used here implement `self.read`
      case packet
      when .is_a? Serverbound::StatusPing
        send_packet Clientbound::StatusPong.new packet.ping_id
      when .is_a? Serverbound::ChatMessage
        Log.info { "[#{username}] [CHAT] #{packet.message}" }
        # TODO commands
        bot.queue_packet packet if forward_chat?
      when .is_a? Serverbound::PlayerBlockPlacement
        next unless forward_place_block?
        # bot.physics.look Look.from_vec(packet.location + packet.cursor)
        bot.send_packet! packet
      end
      # TODO forward raw 0x11 tab_complete, 0x07 statistics, 0x40 select_advancement_tab
    end
  end

  def handle_login_start(username : String)
    Log.info { "[#{username}] Spectator connected" }

    @username = username
    send_packet Clientbound::LoginSuccess.new uuid, username
    connection.state = ProtocolState::PLAY.serverbound

    send_join_game

    send_last_captured 0x67 # tags
    send_last_captured 0x66 # declare_recipes
    # TODO send all unlock_recipes
    send_last_captured 0x12 # declare_commands
    send_last_captured 0x32 # abilities

    send_last_captured 0x0e # difficulty
    send_last_captured 0x3c # resource_pack_send
    send_last_captured 0x57 # simulation_distance

    send_packet Clientbound::HeldItemChange.new bot.player.hotbar_selection

    # allow switching gamemode via F3+N and F3+F4
    send_packet Clientbound::EntityStatus.new entity_id, :op_level4

    player_pos_look_packet = Clientbound::PlayerPositionAndLook.new \
      bot.player.feet, bot.player.look, 0

    send_packet player_pos_look_packet

    send_player_list
    send_last_captured 0x5f # playerlist_header

    send_last_captured 0x59 # update_time

    # spectator must never be dead
    send_packet Clientbound::UpdateHealth.new \
      bot.player.health.clamp(0.1_f32..), bot.player.food, bot.player.saturation

    send_last_captured 0x51 # experience

    send_last_captured 0x49 # update_view_position
    send_last_captured 0x4a # update_view_distance

    # XXX Light Update (One sent for each chunk in a square centered on the player's position)

    bot.dimension.chunks.each_value do |chunk|
      send_packet Clientbound::ChunkData.new chunk
    end

    send_last_captured 0x20 # initialize_world_border
    send_last_captured 0x42 # world_border_center
    send_last_captured 0x43 # world_border_lerp_size
    send_last_captured 0x44 # world_border_size
    send_last_captured 0x45 # world_border_warning_delay
    send_last_captured 0x46 # world_border_warning_reach

    send_last_captured 0x4b # spawn position

    send_packet player_pos_look_packet

    send_packet Clientbound::HeldItemChange.new bot.player.hotbar_selection

    # player inventory
    send_packet Clientbound::WindowItems.new \
      0, bot.inventory.state_id, bot.inventory.slots, bot.inventory.cursor

    if bot.window.id != bot.inventory.id
      win = bot.window
      send_packet Clientbound::OpenWindow.new win.id, win.type_id, win.title
      send_packet Clientbound::WindowItems.new \
        win.id, win.state_id, win.slots, win.cursor
    end

    send_packet Clientbound::SpawnPlayer.new \
      bot.player.entity_id, UUID.new(ENV["UUID"]), bot.player.feet, bot.player.look

    send_entity_equipment

    # TODO other entities

    @joined = true

    spawn do
      while connection.open?
        send_packet Clientbound::KeepAlive.new 1
        sleep 5
      end
    end
  end

  def handle_physics_tick
    return unless joined?
    send_packet Clientbound::EntityTeleport.new \
      bot.player.entity_id, bot.player.feet, bot.player.look, bot.player.on_ground?
  end

  def handle_slot_change
    return unless joined?
    send_entity_equipment
  end

  def handle_respawn(packet : Clientbound::Respawn)
    packet = packet.dup
    packet.gamemode = gamemode
    send_packet packet
  end

  private def send_last_captured(id : UInt8)
    pkt = captures.last?(id) || return
    send_packet pkt
  end

  private def send_join_game
    send_packet(captures.last(Clientbound::JoinGame).dup.tap do |join_game|
      join_game.entity_id = entity_id
      join_game.gamemode = gamemode
      join_game.dimension = bot.dimension.nbt
      join_game.dimension_name = bot.dimension.name
    end)
  end

  private def send_player_list
    list = bot.online_players.values
    list << PlayerList::Entry.new uuid, username, gamemode: gamemode, ping: 0_u32
    send_packet Clientbound::PlayerInfo.new :add, list
  end

  private def send_entity_equipment
    packet = Clientbound::EntityEquipment.new bot.player.entity_id
    packet.main_hand = bot.window.main_hand # inventory won't get updated until window closes
    packet.off_hand = bot.inventory.off_hand
    packet.boots = bot.inventory.boots
    packet.leggings = bot.inventory.leggings
    packet.chestplate = bot.inventory.chestplate
    packet.helmet = bot.inventory.helmet
    send_packet packet if packet.valid?
  end

  def kick(reason : Chat)
    send_packet Clientbound::Disconnect.new reason
    connection.disconnect reason
  end

  def handle_raw_bot_packet(raw_packet : Bytes)
    # TODO RACE CONDITION
    # eg. new entity location may have been captured, but not been forwarded
    # communicate via channel? how to read both spectator socket and bot packet channel?
    return unless joined?
    packet_id = raw_packet[0]
    return if packet_id.in? PACKETS_NOT_FORWARDED
    send_packet raw_packet
  end
end

class Prospect::Captures
  include Rosegold

  getter last_raw = Hash(UInt8, Bytes).new
  getter last_by_entity_id = Hash(UInt32, Array(Clientbound::Packet)).new

  def initialize(@bot : Client); end

  def last?(packet_id : UInt8)
    last_raw[packet_id]?
  end

  def last(packet_id : UInt8)
    last_raw[packet_id]
  end

  def last(packet_type : T.class) : T forall T
    bytes = last_raw[packet_type.packet_id]
    Connection.decode_packet(bytes, ProtocolState::PLAY.clientbound).as T
  end

  def handle_raw_packet(raw_packet : Bytes)
    packet_id = raw_packet[0]
    last_raw[packet_id] = raw_packet # XXX only some packets; and some depend on id (need parsed)
  end

  def handle_destroy_entities(entity_ids : Array(UInt32))
    last_by_entity_id.reject!(&.in?(entity_ids))
  end
end

private PACKETS_NOT_FORWARDED = [
  0x08, # acknowledge_player_digging: response to bot action
  0x18, # custom_payload: could break mods (map)
  # TODO send our own keepalives
  0x1a, # disconnect: world stays around; but show chat
  0x26, # login: custom entity id
  0x30, # ping: answered by bot
  0x31, # craft_recipe_response: response to bot action
  0x38, # position: allow free movement
  0x3d, # respawn: custom gamemode
  0x47, # camera: allow free movement
  0x60, # nbt_query_response: response to bot action
]
