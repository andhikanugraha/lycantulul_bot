load 'Rakefile'

rp = $redis.get('lycantulul::maintenance_prevent').to_i rescue 0
$redis.set('lycantulul::maintenance_prevent', rp ^ 1)

res = $redis.get('lycantulul::maintenance').to_i rescue 0

while res == 0 && (count = Lycantulul::Game.running.count) > 0
  puts "Still #{count} game(s) running, sleeping for 5 seconds"
  sleep(5)
end

puts "Maintenance mode toggling to #{res ^ 1 == 0 ? 'deactivated' : 'activated' }"
$redis.set('lycantulul::maintenance', res ^ 1)
