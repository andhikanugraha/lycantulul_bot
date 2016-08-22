load 'Rakefile'

rp = $redis.get('lycantulul::maintenance_prevent').to_i rescue 0
$redis.set('lycantulul::maintenance_prevent', rp ^ 1)

res = $redis.get('lycantulul::maintenance').to_i rescue 0

Telegram::Bot::Client.run($token) do |bot|
  Lycantulul::Game.running.each do |game|
    $redis.rpush('lycantulul::maintenance_info', game.group_id)
    bot.api.send_message(chat_id: game.group_id, text: 'Abis ini mau main tenis bentar yak, nungguin pada selese main dulu. Bentar doang kok.') rescue nil
  end
end

while res == 0 && (count = Lycantulul::Game.running.count) > 0
  puts "Still #{count} game(s) running, sleeping for 30 seconds"
  sleep(30)
end

Telegram::Bot::Client.run($token) do |bot|
  bot.api.send_message(chat_id: Lycantulul::RegisteredPlayer.find_by(username: 'araishikeiwai').user_id, text: 'MAINTENANCE TOGGLED') rescue nil
end

puts "Maintenance mode toggling to #{res ^ 1 == 0 ? 'deactivated' : 'activated' }"
$redis.set('lycantulul::maintenance', res ^ 1)

if res == 1
  queue = $redis.lrange('lycantulul::maintenance_info', 0, -1).uniq
  puts "Sending 'im back' to #{queue.size} chats"
  Telegram::Bot::Client.run($token) do |bot|
    queue.each do |q|
      bot.api.send_message(chat_id: q, text: 'Sudah selesai bermain tenis. Silakan mulai main lagi~') rescue nil
      sleep(0.05)
    end
  end
  $redis.del('lycantulul::maintenance_info')
end
