# Conductrics wrapper
class window.ConductricsJS
	constructor: (@owner, @apikey, @opts = {}) ->
		@opts.server ?= '//api.conductrics.com'
		@opts.timeout ?= 5000
		@opts.cookies ?= {ttl:(60*60*24*30), path:'/'}
		@opts.scodestore ?= CookieLite # pluggable - expected to be a getter/setter function that implements fn('key') for reads and fn('key', val) for writes
		@opts.session ?= @opts.scodestore?('mpid')
		@opts.transport ?= MicroAjax # pluggable - expected to be a factory that implements constructor args (url, timeout, cb)
		@opts.batching ?= 'off'
		@opts.batchingSkipsPreflight ?= true
		@batchStart() if @opts.batching in ['auto','manual']

	decision: (agent, opts = {}, cb = null) =>
		url = [agent, 'decisions']
		fb = null # fallback
		if opts.choices? # if provided, serialize decision/choice codes and determine fallback
			for key,val of opts.choices when val?.join?
				url.push "#{key}:#{val.join ','}" # when done and joined, something like: "/decisions/size:small,big/color:red,blue,green"
				fb ?= {}; fb[key] = code:val[0] unless fb[key]
			delete opts.choices
		if opts.fallback? # allow explicit fallback to be provided
			fb = opts.fallback
			delete opts.fallback
		@send url, opts, null, true, (res) =>
			keepId @opts, res?.session
			return unless cb?
			selection = res?.decisions ? fb
			cb selection, res?.session

	goal: (agent, opts, cb) =>
		url = [agent, 'goal']
		if opts.goal? # if provided, add goal code to the url
			url.push opts.goal
			delete opts.goal
		@send url, opts, null, true, (res) =>
			keepId @opts, res?.session
			return unless cb?
			accepted = res?.reward > 0 # if Conductrics returns 0 for the reward, it didn't accept the goal (probably the session expired, or no prior decision was made, or the reward was rejected because it was too big or was already received)
			retryable = not res?.agent? # if the Conductrics response contains the agent, we did get an answer back from Conductrics (not a network error) so there's no point in retrying
			cb accepted, res?.session, retryable

	send: (url, data, body, batchable, cb) =>
		data.apikey = @apikey
		data.session = @opts.session if @opts.session?
		data._t = new Date().getTime()
		# if batching
		if batchable and @opts.batching in ['auto','manual']
			@batch.push _batchItem(url, data, cb) # the callback will be called later, after we send the batch
			_batchSend(@) if @opts.batching is 'auto' # if it's manual, the user is supposed to call batchSend() themselves
			return
		# not batching
		url = "#{@opts.server}/#{@owner}/#{url.join '/'}?#{qsformat data}"
		new @opts.transport url, body, @opts.timeout, (text) =>
			try
				res = JSON.parse text
				cb res
			catch e
				cb null

	# helpers
	qsformat = (data) -> qs = ''; qs += "&#{k}=#{escape v}" for k,v of data; return qs
	keepId = (opts, session) ->
		if session? and opts.cookies?
			opts.session = session
			opts.scodestore?('mpid', session, opts.cookies)
	debounce = (ms, f) ->
		timeout = null
		(a...) ->
			clearTimeout timeout
			setTimeout (=>
				f.apply @, a
			), ms

	# batch management
	batchStart: -> @batch = []
	batchSend: ->
		url = ['-','batch']
		batched = @batch.concat() # make a copy so we can reset the @batch array
		@batchStart() # reset the @batch array
		return unless batched.length > 0 # nothing to do
		params = if @opts.batchingSkipsPreflight then {_type:'json'} else {} # add &_type=json to indicate content type (workaround for CORS preflight requirement)
		@send url, params, batched, false, (results) ->
			for i of batched
				item = results?[i]
				batched[i].cb(item?.data) # call each deferred callback with the corresponding data - if no data for the callback, call it anyway with 'undefined'
	_batchSend = debounce 20, (self) -> self.batchSend()
	_batchItem = (url, data, cb) ->
		item =
			agent: url[0]
			type: url[1]
			query: data
			cb: cb
		switch item.type
			when 'decisions'
				item.choices = url[2..].join('/') if url.length > 2
			when 'goal'
				item.goal = url[2] if url.length > 2
		return item

