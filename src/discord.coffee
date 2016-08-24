# Description:
#   Adapter for Hubot to communicate on Discord
#
# Commands:
#   None
#
# Configuration:
#   HUBOT_DISCORD_HELP_REPLY_IN_PRIVATE - whether or not to reply to help messages in private, defaults to false
#   HUBOT_MAX_MESSAGE_LENGTH - maximum allowable message length (defaults to 2000, discord's default)
#   HUBOT_DISCORD_EMAIL - authentication email for bot account (optional)
#   HUBOT_DISCORD_PASSWORD - authentication password for bot account (optional)
#   HUBOT_DISCORD_TOKEN - authentication token for bot
#   HUBOT_DISCORD_CARBON_TOKEN - Carbonitex.net bot authentication
#   HUBOT_DISCORD_BOTS_WEB_USER - bots.discord.pw user id for bot
#   HUBOT_DISCORD_BOTS_WEB_TOKEN - bots.discord.pw auth token
#   HUBOT_DISCORD_STATUS_MSG - Status message to set for "currently playing game"
#   
# Notes:
# 

try
		{Robot, Adapter, EnterMessage, LeaveMessage, TopicMessage, TextMessage}  = require 'hubot'
catch
		prequire = require( 'parent-require' )
		{Robot, Adapter, EnterMessage, LeaveMessage, TopicMessage, TextMessage}  = prequire 'hubot'
Discord = require 'discord.js'
request = require 'request'

rooms = {}

maxLength = parseInt process.env.HUBOT_MAX_MESSAGE_LENGTH || 2000
replyInPrivate = process.env.HUBOT_DISCORD_HELP_REPLY_IN_PRIVATE || false
carbonToken = process.env.HUBOT_DISCORD_CARBON_TOKEN
discordBotsWebUser = process.env.HUBOT_DISCORD_BOTS_WEB_USER
discordBotsWebToken = process.env.HUBOT_DISCORD_BOTS_WEB_TOKEN
currentlyPlaying = process.env.HUBOT_DISCORD_STATUS_MSG || ''
zSWC = '\u200B'

class DiscordBot extends Adapter
	constructor: (robot)->
		super
		@robot = robot

	run: ->
		@options =
			email: process.env.HUBOT_DISCORD_EMAIL,
			password: process.env.HUBOT_DISCORD_PASSWORD,
			token: process.env.HUBOT_DISCORD_TOKEN

		@client = new Discord.Client {forceFetchUsers: true, autoReconnect: true}
		@client.on 'ready', @ready
		@client.on 'message', @message
				
		if @options.token?
			@client.loginWithToken @options.token, @options.email, @options.password, (err) ->
				@robot.logger.error err
		else
			@client.login @options.email, @options.password, (err) ->
				@robot.logger.error err

	ready: =>
		@robot.logger.info "Logged in: #{@client.user.username}"
		@robot.name = @client.user.username.toLowerCase()
		@robot.logger.info "Robot Name: #{@robot.name}"
		@emit 'connected'

		# post-connect actions
		rooms[channel.id] = channel for channel in @client.channels
		setInterval @updateCarbonitex, 600000
		setInterval @updateDiscordBotsWeb, 60000
		@client.setStatus 'here', currentlyPlaying, (err) ->
			@robot.logger.error err

	message: (message) =>
		# ignore messages from myself
		return if message.author.id is @client.user.id

		user = @robot.brain.userForId message.author.id
		user.room = message.channel.id
		user.name = message.author.name
		user.id = message.author.id
		rooms[message.channel.id] ?= message.channel

		text = message.cleanContent 
		if (message.channel instanceof Discord.PMChannel)
			text = "#{@robot.name}: #{text}" if not text.match new RegExp( "^@?#{@robot.name}" )

		@robot.logger.debug text
		@receive new TextMessage( user, text, message.id )
		 
	chunkMessage: (msg) =>
		subMessages = []
		if(msg.length > maxLength)
			while msg.length > 0
				# Split message at last line break, if it exists
				chunk = msg.substring(0, maxLength)
				breakIndex = if chunk.lastIndexOf('\n') isnt -1 then chunk.lastIndexOf('\n') else maxLength
				subMessages.push msg.substring(0, breakIndex)
				# Skip char if split on line break
				breakIndex++ if breakIndex isnt maxLength
				msg = msg.substring(breakIndex, msg.length)
		else subMessages.push(msg)
		return subMessages

	send: (envelope, messages...) ->
		for msg in messages
			room = rooms[envelope.room]
			if (replyInPrivate)
				try
					user = envelope.user.id
				catch err
					@robot.logger.debug "Error fetching user id from envelope - #{err}"
					user = room
				checkPrivateMsgNotif = "@user, check your messages for help."
				if(process.env.HUBOT_DISCORD_HELP_MESSAGE)
					checkPrivateMsgNotif = process.env.HUBOT_DISCORD_HELP_MESSAGE            
				try
					if(envelope.message and envelope.message.match(/help(?:\s+(.*))?$/))
						for m in this.chunkMessage msg
							@client.sendMessage @client.users.get("id", user), m, (err) -> 
								@robot.logger.debug  "Error parsing users from client - #{err}"
						@client.sendMessage room, checkPrivateMsgNotif.replace /user/, user , (err) ->
							@robot.logger.debug "Error sending message privately - #{err}"
					else
						@client.sendMessage(room, zSWC+m, (err) -> @robot.logger.error err) for m in this.chunkMessage msg
				catch err
					@robot.logger.debug "Couldn't send message - #{err}"
			else
				@client.sendMessage(room, zSWC+m, (err) -> @robot.logger.error err) for m in this.chunkMessage msg

	reply: (envelope, messages...) ->
		# discord.js reply function looks for a 'sender' which doesn't 
		# exist in our envelope object
		user = envelope.user.name
		for msg in messages
			@client.sendMessage rooms[envelope.room], "#{zSWC}#{user} #{msg}", (err) ->
						@robot.logger.error err
	
	updateDiscordBotsWeb: ->
		if discordBotsWebToken? and discordBotsWebUser?
			@robot.logger.debug 'Updating discord bots'
			@robot.logger.debug "#{@robot.name} is on #{@client.servers.length} servers"
			requestBody =
				method: 'POST'
				url: "https://bots.discord.pw/api/bots/#{discordBotsWebUser}/stats"
				headers:
					Authorization: discordBotsWebToken
				body:
					server_count: @clients.servers.length
				json: true
			@doRequest requestBody

	updateCarbonitex: ->
		if carbonToken?
			@robot.logger.debug 'Updating Carbonitex'
			@robot.logger.debug "#{@robot.name} is on #{@client.servers.length} servers"
			requestBody =
				url: 'https://www.carbonitex.net/discord/data/botdata.php'
				body:
					key: carbonToken
					servercount: @client.servers.length
				json: true
			@doRequest requestBody

	doRequest: (requestBody) ->
		request requestBody, (err, response, body) ->
			if not err and response.statusCode is 200
				@robot.logger.debug body
			else if err
				@robot.logger.error err
			else
				@robot.logger.error "Bad request or other error - #{response.body.error}"
				@robot.logger.error requestBody


exports.use = (robot) ->
	new DiscordBot robot
