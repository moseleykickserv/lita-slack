module Lita
  module Adapters
    class Slack < Adapter
      # @api private
      class MessageHandler
        attr_accessor :websocket

        def initialize(robot, robot_id, data, config)
          @robot = robot
          @robot_id = robot_id
          @data = data
          @type = data["type"]
          @config = config
        end

        def handle
          case type
          when "hello"
            handle_hello
          when "message"
            handle_message
          when "reaction_added", "reaction_removed"
            handle_reaction
          when "user_change", "team_join"
            handle_user_change
          when "bot_added", "bot_changed"
            handle_bot_change
          when "channel_created", "channel_rename", "group_rename"
            handle_channel_change
          when "error"
            handle_error
          else
            handle_unknown
          end
        end

        private

        attr_reader :config
        attr_reader :data
        attr_reader :robot
        attr_reader :robot_id
        attr_reader :type

        def body
          normalized_message = if data["text"]
            # Replace mentions anywhere in the message, not just at the start
            data["text"].gsub(/<@#{robot_id}>/, "@#{robot.mention_name}")
          end

         normalized_message = remove_formatting(normalized_message) unless normalized_message.nil?

          attachment_text = Array(data["attachments"]).map do |attachment|
            attachment["text"] || attachment["fallback"]
          end

          ([normalized_message] + attachment_text).compact.join("\n")
        end

        def remove_formatting(message)
          # https://api.slack.com/docs/formatting
          message = message.gsub(/
              <                    # opening angle bracket
              (?<type>[@#!])?      # link type
              (?<link>[^>|]+)      # link
              (?:\|                # start of |label (optional)
                  (?<label>[^>]+)  # label
              )?                   # end of label
              >                    # closing angle bracket
              /ix) do
            link  = Regexp.last_match[:link]
            label = Regexp.last_match[:label]

            case Regexp.last_match[:type]
              when '@'
                if label
                  label
                else
                  user = User.find_by_id(link)
                  if user
                    "@#{user.mention_name}"
                  else
                    "@#{link}"
                  end
                end

              when '#'
                if label
                  label
                else
                  channel = Lita::Room.find_by_id(link)
                  if channel
                    "\##{channel.name}"
                  else
                    "\##{link}"
                  end
                end

              when '!'
                "@#{link}" if ['channel', 'group', 'everyone'].include? link
              else
                link = link.gsub(/^mailto:/, '')
                if label && !(link.include? label)
                  "#{label} (#{link})"
                else
                  label == nil ? link : label
                end
            end
          end
          message.gsub('&lt;', '<')
                 .gsub('&gt;', '>')
                 .gsub('&amp;', '&')

        end

        def channel
          data["channel"]
        end

        def dispatch_message(user)
          room = Lita::Room.find_by_id(channel)
          source = Source.new(user: user, room: room || channel)
          source.private_message! if channel && channel[0] == "D"
          message = Message.new(robot, body, source)
          # Mark as command if it's a private message or if the bot is mentioned
          is_mentioned = mentioned?
          if source.private_message? || is_mentioned
            message.command!
            log.debug("Marking message as command. Private: #{source.private_message?}, Mentioned: #{is_mentioned}")
          end
          message.extensions[:slack] = { timestamp: data["ts"] }
          log.debug("Dispatching message to Lita from #{user.id}. Text: #{data["text"]}, Body: #{body}, Mention name: #{robot.mention_name}, Robot ID: #{robot_id}")
          robot.receive(message)
        end

        def mentioned?
          return false unless data["text"]
          text = data["text"]
          text_lower = text.downcase
          
          # First check for Slack mention format <@USER_ID>
          if text.include?("<@#{robot_id}>")
            log.debug("Mention detected via Slack format: <@#{robot_id}>")
            return true
          end
          
          # Then check for @mention_name or just mention_name
          mention_name = robot.mention_name&.downcase
          if mention_name
            # Check for @mention_name format
            if text_lower.include?("@#{mention_name}")
              log.debug("Mention detected via @mention_name format")
              return true
            end
            
            # Check for just mention_name as a word (with word boundaries)
            mention_pattern = /\b#{Regexp.escape(mention_name)}\b/i
            if text.match(mention_pattern)
              log.debug("Mention detected via mention_name word match")
              return true
            end
          end
          
          log.debug("No mention detected. text=#{text}, robot_id=#{robot_id}, mention_name=#{mention_name}")
          false
        end

        def from_self?(user)
          user.id == robot_id
        end

        def handle_bot_change
          log.debug("Updating user data for bot.")
          UserCreator.create_user(SlackUser.from_data(data["bot"]), robot, robot_id)
        end

        def handle_channel_change
          log.debug("Updating channel data.")
          RoomCreator.create_room(SlackChannel.from_data(data["channel"]), robot)
        end

        def handle_error
          error = data["error"]
          code = error["code"]
          message = error["msg"]
          log.error("Error with code #{code} received from Slack: #{message}")
        end

        def handle_hello
          log.info("Connected to Slack.")
          # Send presence update to show bot as online in Socket Mode
          if websocket
            websocket.send(MultiJson.dump({ type: "presence_sub", presence: "active" }))
          end
          robot.trigger(:connected)
        end

        def handle_message
          log.debug("Received message event: #{data.inspect}")
          return unless supported_subtype?
          return if data["user"] == 'USLACKBOT'

          user = User.find_by_id(data["user"]) || User.create(data["user"])

          return if from_self?(user)

          dispatch_message(user)
        end

        def handle_reaction
          log.debug "#{type} event received from Slack"

          # find or create user
          user = User.find_by_id(data["user"]) || User.create(data["user"])

          # avoid processing reactions added/removed by self
          return if from_self?(user)

          # find or create item_user
          item_user = User.find_by_id(data["item_user"]) || User.create(data["item_user"])

          # build a payload following slack convention for reactions
          payload = { user: user, name: data["reaction"], item_user: item_user, item: data["item"], event_ts: data["event_ts"] }

          # trigger the appropriate slack reaction event
          robot.trigger("slack_#{type}".to_sym, payload)
        end

        def handle_unknown
          unless data["reply_to"]
            log.debug("#{type} event received from Slack and will be ignored.")
          end
        end

        def handle_user_change
          log.debug("Updating user data.")
          UserCreator.create_user(SlackUser.from_data(data["user"]), robot, robot_id)
        end

        def log
          Lita.logger
        end

        # Types of messages Lita should dispatch to handlers.
        def supported_message_subtypes
          (config && config.supported_message_subtypes).to_a + %w(me_message)
        end

        def supported_subtype?
          subtype = data["subtype"]

          if subtype
            supported_message_subtypes.include?(subtype)
          else
            true
          end
        end
      end
    end
  end
end
