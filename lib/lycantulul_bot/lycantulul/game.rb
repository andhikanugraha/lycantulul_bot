module Lycantulul
  class Game
    include Mongoid::Document

    VILLAGER = 0
    WEREWOLF = 1
    SEER = 2
    PROTECTOR = 3
    NECROMANCER = 4
    SILVER_BULLET = 5

    RESPONSE_OK = 0
    RESPONSE_INVALID = 1
    RESPONSE_DOUBLE = 2
    RESPONSE_SKIP = 3

    NECROMANCER_SKIP = 'AKU BELUM MAU MATI MAS!'

    field :group_id, type: Integer
    field :night, type: Boolean, default: true
    field :waiting, type: Boolean, default: true
    field :finished, type: Boolean, default: false
    field :victim, type: Array, default: []
    field :votee, type: Array, default: []
    field :seen, type: Array, default: []
    field :protectee, type: Array, default: []
    field :necromancee, type: Array, default: []

    index({ group_id: 1, finished: 1 })
    index({ finished: 1, waiting: 1, night: 1 })

    has_many :players, class_name: 'Lycantulul::Player'

    def self.create_from_message(message)
      res = self.create(group_id: message.chat.id)
      res.add_player(message.from)
    end

    def self.active_for_group(group)
      self.find_by(group_id: group.id, finished: false)
    end

    def add_player(user)
      return false if self.players.with_id(user.id)
      return self.players.create_player(user, self.id)
    end

    def remove_player(user)
      return false unless self.players.with_id(user.id)
      return self.players.with_id(user.id).destroy
    end

    def restart
      self.players.map(&:reset_state)
      self.night = true
      self.waiting = true
      self.finished = false
      self.victim = []
      self.votee = []
      self.seen = []
      self.protectee = []
      self.save
    end

    def add_victim(killer_id, victim)
      return RESPONSE_DOUBLE if self.victim.any?{ |vi| vi[:killer_id] == killer_id }
      return RESPONSE_INVALID unless valid_action?(killer_id, victim, 'werewolf')

      new_victim = {
        killer_id: killer_id,
        full_name: victim
      }
      self.victim << new_victim
      self.save
      RESPONSE_OK
    end

    def add_votee(voter_id, votee)
      return RESPONSE_DOUBLE if self.votee.any?{ |vo| vo[:voter_id] == voter_id }
      return RESPONSE_INVALID unless valid_action?(voter_id, votee, 'player')

      new_votee = {
        voter_id: voter_id,
        full_name: votee
      }
      self.votee << new_votee
      self.save
      RESPONSE_OK
    end

    def add_seen(seer_id, seen)
      return RESPONSE_DOUBLE if self.seen.any?{ |se| se[:seer_id] == seer_id }
      return RESPONSE_INVALID unless valid_action?(seer_id, seen, 'seer')

      new_seen = {
        seer_id: seer_id,
        full_name: seen
      }
      self.seen << new_seen
      self.save
      RESPONSE_OK
    end

    def add_protectee(protector_id, protectee)
      return RESPONSE_DOUBLE if self.protectee.any?{ |se| se[:protector_id] == protector_id }
      return RESPONSE_INVALID unless valid_action?(protector_id, protectee, 'protector')

      new_protectee = {
        protector_id: protector_id,
        full_name: protectee
      }
      self.protectee << new_protectee
      self.save
      RESPONSE_OK
    end

    def add_necromancee(necromancer_id, necromancee)
      return RESPONSE_DOUBLE if self.necromancee.any?{ |se| se[:necromancer_id] == necromancer_id }
      return RESPONSE_SKIP if necromancee == NECROMANCER_SKIP
      return RESPONSE_INVALID unless valid_action?(necromancer_id, necromancee, 'necromancer')

      new_necromancee = {
        necromancer_id: necromancer_id,
        full_name: necromancee
      }
      self.necromancee << new_necromancee
      self.save
      RESPONSE_OK
    end

    def start
      self.update_attribute(:waiting, false)
      assign(WEREWOLF)
      assign(SEER)
      assign(PROTECTOR)
      assign(NECROMANCER)
      assign(SILVER_BULLET)
    end

    def assign(role)
      role_count(role).times do
        self.living_villagers.sample.assign(role)
        LycantululBot.log("assigning #{get_role(role)}")
      end
    end

    def finish
      self.update_attribute(:finished, true)
    end

    def kill_victim
      vc = self.victim.group_by{ |vi| vi[:full_name] }.map{ |k, v| [k, v.count] }.sort_by{ |vi| vi[1] }.compact.reverse
      LycantululBot.log(vc.to_s)
      self.update_attribute(:victim, [])
      self.update_attribute(:night, false)

      if vc.count == 1 || (vc.count > 1 && vc[0][1] > vc[1][1])
        victim = self.living_players.with_name(vc[0][0])
        if !under_protection?(victim.full_name)
          victim.kill
          LycantululBot.log("#{victim.full_name} is mauled (from GAME)")
          dead_werewolf =
            if victim.role == SILVER_BULLET
              ded = self.living_werewolves.sample
              ded.kill
              LycantululBot.log("#{ded.full_name} is killed because werewolves killed a silver bullet (from GAME)")
              ded
            end

          return [victim.user_id, victim.full_name, self.get_role(victim.role), dead_werewolf]
        end
      end

      nil
    end

    def kill_votee
      vc = self.votee.group_by{ |vo| vo[:full_name] }.map{ |k, v| [k, v.count] }.sort_by{ |vo| vo[1] }.reverse
      LycantululBot.log(vc.to_s)
      self.update_attribute(:votee, [])
      self.update_attribute(:night, true)

      if vc.count == 1 || (vc.count > 1 && vc[0][1] > vc[1][1])
        votee = self.living_players.with_name(vc[0][0])
        votee.kill
        LycantululBot.log("#{votee.full_name} is executed (from GAME)")
        return [votee.user_id, votee.full_name, self.get_role(votee.role)]
      end

      nil
    end

    def enlighten_seer
      ss = self.seen
      LycantululBot.log(ss.to_s)
      self.update_attribute(:seen, [])

      res = []
      ss && ss.each do |vc|
        seen = self.living_players.with_name(vc[:full_name])
        if seen && self.living_seers.with_id(vc[:seer_id])
          LycantululBot.log("#{seen.full_name} is seen (from GAME)")
          res << [seen.full_name, self.get_role(seen.role), vc[:seer_id]]
        end
      end

      res
    end

    def protect_players
      ss = self.protectee
      LycantululBot.log(ss.to_s)
      self.update_attribute(:protectee, [])

      return nil unless self.living_protectors.count > 0

      res = []
      ss && ss.each do |vc|
        protectee = self.living_players.with_name(vc[:full_name])
        if protectee.role == WEREWOLF && rand.round + rand.round < 3 # 25% ded if protecting werewolf
          ded = self.living_players.with_id(vc[:protector_id])
          ded.kill
          LycantululBot.log("#{ded.full_name} is killed because they protected werewolf (from GAME)")
          res << [ded.full_name, ded.user_id]
        end
      end

      res
    end

    def raise_the_dead
      ss = self.necromancee
      LycantululBot.log(ss.to_s)
      self.update_attribute(:necromancee, [])

      res = []
      ss && ss.each do |vc|
        necromancee = self.dead_players.with_name(vc[:full_name])
        if necromancee && (necromancer = self.living_necromancers.with_id(vc[:necromancer_id]))
          LycantululBot.log("#{necromancee.full_name} is raised from the dead by #{necromancer.full_name} (from GAME)")
          necromancee.revive
          necromancer.kill
          res << [necromancee.full_name, self.get_role(necromancee.role), necromancer.full_name, necromancee.user_id, vc[:necromancer_id]]
        end
      end

      res
    end

    def under_protection?(victim_name)
      self.protectee.any?{ |pr| pr[:full_name] == victim_name }
    end

    def valid_action?(actor_id, actee_name, action)
      actor = eval("self.living_#{action}".pluralize).with_id(actor_id)

      actee =
        if action == 'werewolf'
          self.killables.with_name(actee_name)
        elsif action == 'necromancer'
          return true if actee_name == NECROMANCER_SKIP
          self.dead_players.with_name(actee_name)
        else
          self.living_players.with_name(actee_name)
        end

      actor && actee && actor.user_id != actee.user_id
    end

    def list_players
      liv_count = self.living_players.count
      ded_count = self.dead_players.count

      res = "Masi idup: #{liv_count} makhluk\n"

      if self.finished
        res += self.living_players.map{ |lp| "#{lp.full_name} - #{self.get_role(lp.role)}" }.sort.join("\n")
      else
        res += self.living_players.map(&:full_name).sort.join("\n")
      end

      if ded_count > 0
        res += "\n\n"
        res += "Udah mati: #{ded_count} makhluk\n"
        res += (self.dead_players).map{ |lp| "#{lp.full_name} - #{self.get_role(lp.role)}" }.sort.join("\n")
      end

      if self.waiting?
        res += "\n\n/ikutan yuk pada~ yang udah ikutan jangan pada /gajadi"
      end

      res
    end

    def get_role(role)
      case role
      when VILLAGER
        'Warga kampung'
      when WEREWOLF
        'TTS'
      when SEER
        'Tukang intip'
      when PROTECTOR
        'Penjual jimat'
      when NECROMANCER
        'Mujahid'
      when SILVER_BULLET
        'Pengidap ebola'
      end
    end

    def get_task(role)
      case role
      when VILLAGER
        'Diam menunggu kematian. Seriously. Tapi bisa bantu-bantu yang lain lah sumbang suara buat bunuh para serigala, sekalian berdoa biar dilindungi sama penjual jimat kalo ada'
      when WEREWOLF
        "Tulul-Tulul Serigala -- BUNUH, BUNUH, BUNUH\n\nSetiap malam, bakal ditanya mau bunuh siapa (oiya, kalo misalnya ada serigala yang lain, kalian harus berunding soalnya ntar voting, kalo ga ada suara mayoritas siapa yang mau dibunuh, ga ada yang mati, ntar gua kasih tau kok pas gua tanyain)\n\nHati-hati, bisa jadi ada pengidap ebola di antara para warga kampung, kalo bunuh dia, 1 ekor serigala akan ikut mati"
      when SEER
        'Bantuin kemenangan para rakyat jelata dengan ngintipin ke rumah orang-orang. Pas ngintip ntar bisa tau mereka siapa sebenarnya. Tapi kalo misalnya yang mau diintip (atau elunya sendiri) mati dibunuh serigala, jadi gatau dia siapa sebenarnya :\'( hidup memang keras'
      when PROTECTOR
        'Jualin jimat ke orang-orang. Orang yang dapet jimat akan terlindungi dari serangan para serigala. Ntar tiap malem ditanyain mau jual ke siapa (sebenernya ga jualan juga sih, ga dapet duit, maap yak). Hati-hati loh tapi, kalo lu jual jimat ke serigala bisa-bisa lu dibunuh dengan 25% kemungkinan, kecil lah, peluang lu buat dapet pasangan hidup masih lebih gede :)'
      when NECROMANCER
        'Menghidupkan kembali 1 orang mayat. Sebagai gantinya, lu yang bakal mati. Ingat, cuma ada 1 kesempatan! Dan jangan sampe lu malah dibunuh duluan sama serigala. Allaaaaahuakbar!'
      when SILVER_BULLET
        'Diam menunggu kematian. Tapi, kalu lu dibunuh serigala, 1 ekor serigalanya ikutan mati. Aduh itu kenapa kena ebola lu ga dikarantina aja sih'
      end
    end

    def role_count(role)
      base_count = self.players.count - LycantululBot::MINIMUM_PLAYER.call
      case role
      when WEREWOLF
        (base_count / 4) + 1 # [5-8, 1], [9-12, 2], ...
      when SEER
        (base_count / 8) + 1 # [5-12, 1], [13-20, 2], ...
      when PROTECTOR
        ((base_count - 3) / 9) + 1 # [8-16, 1], [17-25, 2], ...
      when NECROMANCER
        base_count > 6 ? 1 : 0
      when SILVER_BULLET
        base_count > 8 ? 1 : 0
      end
    end

    def living_players
      self.players.alive
    end

    def living_villagers
      self.living_players.with_role(VILLAGER)
    end

    def living_werewolves
      self.living_players.with_role(WEREWOLF)
    end

    def living_seers
      self.living_players.with_role(SEER)
    end

    def living_protectors
      self.living_players.with_role(PROTECTOR)
    end

    def living_necromancers
      self.living_players.with_role(NECROMANCER)
    end

    def living_silver_bullets
      self.living_players.with_role(SILVER_BULLET)
    end

    def killables
      self.living_players.without_role(WEREWOLF)
    end

    def dead_players
      self.players.dead
    end
  end
end
