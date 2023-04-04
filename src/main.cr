require "rosegold"
require "./prospect"

client = Rosegold::Client.new ENV["HOST"]

server = Prospect::Server.new client

client.join_game

puts "Client ready"

while gets; end # TODO add commands/launch script/etc
