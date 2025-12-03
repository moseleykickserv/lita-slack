require 'faraday'

require 'lita/adapters/slack/team_data'
require 'lita/adapters/slack/slack_im'
require 'lita/adapters/slack/slack_user'
require 'lita/adapters/slack/slack_channel'

module Lita
  module Adapters
    class Slack < Adapter
      # @api private
      class API
        def initialize(config, stubs = nil)
          @config = config
          @stubs = stubs
          @post_message_config = {}
          @post_message_config[:parse] = config.parse unless config.parse.nil?
          @post_message_config[:link_names] = config.link_names ? 1 : 0 unless config.link_names.nil?
          @post_message_config[:unfurl_links] = config.unfurl_links unless config.unfurl_links.nil?
          @post_message_config[:unfurl_media] = config.unfurl_media unless config.unfurl_media.nil?
        end

        def im_open(user_id)
          response_data = call_api("conversations.open", users: user_id)

          SlackIM.new(response_data["channel"]["id"], user_id)
        end

        def channels_info(channel_id)
          call_api("channels.info", channel: channel_id)
        end

        def channels_list
          call_api("channels.list")
        end

        def groups_list
          call_api("groups.list")
        end

        def mpim_list
          call_api("mpim.list")
        end

        def im_list
          call_api("im.list")
        end

        def users_list
          call_api("users.list")
        end

        def send_attachments(room_or_user, attachments)
          call_api(
            "chat.postMessage",
            channel: room_or_user.id,
            attachments: MultiJson.dump(attachments.map(&:to_hash)),
          )
        end

        def send_messages(channel_id, messages)
          call_api(
            "chat.postMessage",
            **post_message_config,
            channel: channel_id,
            text: messages.join("\n"),
          )
        end

        def set_topic(channel, topic)
          call_api("channels.setTopic", channel: channel, topic: topic)
        end

        def rtm_start
          # Use Socket Mode if app_token is configured, otherwise fall back to RTM
          if config.app_token
            # Socket Mode: Get WebSocket URL using app-level token
            socket_response = call_api("apps.connections.open", {}, config.app_token)
            
            # Get bot info using bot token
            bot_info = call_api("auth.test")
            
            # Create a self user object from bot info
            self_user = {
              "id" => bot_info["user_id"],
              "name" => bot_info["user"],
              "real_name" => bot_info["user"]
            }
            
            TeamData.new(
              SlackIM.from_data_array([]),
              SlackUser.from_data(self_user),
              SlackUser.from_data_array([]),     # users
              SlackChannel.from_data_array([]) + # channels
                SlackChannel.from_data_array([]),# groups
              socket_response["url"],
            )
          else
            # RTM Mode: Use rtm.connect
            response_data = call_api("rtm.connect")

            TeamData.new(
              SlackIM.from_data_array([]),
              SlackUser.from_data(response_data["self"]),
              SlackUser.from_data_array([]),     # users
              SlackChannel.from_data_array([]) + # channels
                SlackChannel.from_data_array([]),# groups
              response_data["url"],
            )
          end
        end

        private

        attr_reader :stubs
        attr_reader :config
        attr_reader :post_message_config

        def call_api(method, post_data = {}, token_override = nil)
          token = token_override || config.token
          
          # For apps.connections.open (Socket Mode), app-level token must be sent as Bearer token in header
          if method == "apps.connections.open" && token_override
            response = connection.post do |req|
              req.url "https://slack.com/api/#{method}"
              req.headers['Authorization'] = "Bearer #{token}"
              # apps.connections.open doesn't require a body - only the Authorization header
            end
          else
            # For other endpoints, use token as POST parameter
            response = connection.post(
              "https://slack.com/api/#{method}",
              { token: token }.merge(post_data)
            )
          end

          data = parse_response(response, method)

          if data["error"]
            error_msg = "Slack API call to #{method} returned an error: #{data["error"]}."
            if data["error"] == "missing_scope" && data["needed"]
              error_msg += " Required scope: #{data["needed"]}. Please add this scope in your Slack app's OAuth & Permissions settings and reinstall the app."
            elsif data["error"] == "missing_scope"
              error_msg += " For #{method}, you likely need the 'chat:write' scope. Please add it in your Slack app's OAuth & Permissions settings and reinstall the app."
            end
            raise error_msg
          end

          data
        end

        def connection
          if stubs
            Faraday.new { |faraday| faraday.adapter(:test, stubs) }
          else
            options = {}
            unless config.proxy.nil?
              options = { proxy: config.proxy }
            end
            Faraday.new(options)
          end
        end

        def parse_response(response, method)
          unless response.success?
            raise "Slack API call to #{method} failed with status code #{response.status}: '#{response.body}'. Headers: #{response.headers}"
          end

          MultiJson.load(response.body)
        end
      end
    end
  end
end
