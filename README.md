# Prospect

Spectator/proxy server for [Rosegold](https://github.com/RosegoldMC/rosegold.cr)

## Usage

```crystal
require "rosegold"
require "prospect"
client = Rosegold::Client.new "localhost"
server = Prospect::Server.new client, port=25566
client.join_game
while gets; end
```
