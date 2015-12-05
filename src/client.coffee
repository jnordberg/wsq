### Client implementation. ###

async = require 'async'
dnode = require 'dnode'
multiplex = require 'multiplex'
WebSocket = require 'websocket-stream'
{PassThrough} = require 'stream'

{EventEmitter} = require 'events'
{Worker} = require './worker'
{Task} = require './task'
{Stream} = require 'stream'
{randomString} = require './common'

# workaround for browsers where not all streams will inherit from browserifys Stream class
# TODO: more robust stream detection
isStream = (value) -> value instanceof Stream or value.readable is true

class Client extends EventEmitter

  defaults =
    backoff: (tries) -> Math.min (tries * 10) ** 2, 60 * 1000

  constructor: (@address, options={}) ->
    @ready = false
    @workers = []
    @queues = {}
    @activeStreams = {}

    @options = {}
    for key of defaults
      @options[key] = options[key] ? defaults[key]

    @subscribed = false

    @setMaxListeners Infinity
    @connectionTries = 0
    @connect()

  connect: ->
    @closed = false
    throw new Error 'Already connected!' if @socket?
    @socket = new WebSocket @address
    @socket.on 'close', =>
      wasOpen = @remote?
      @socket = null
      @remote = null
      @onDisconnect() if wasOpen
      unless @closed
        delay = @options.backoff @connectionTries++
        setTimeout @connect.bind(this), delay
    @socket.on 'error', (error) => @emit 'error', error
    @rpc = dnode null, {weak: false}
    @rpc.on 'remote', (remote) =>
      @remote = remote
      @connectionTries = 0
      @onConnect()
    @multiplex = multiplex()
    @socket.pipe(@multiplex).pipe(@socket)
    rpcStream = @multiplex.createSharedStream 'rpc'
    rpcStream.pipe(@rpc).pipe(rpcStream)

  close: ->
    @closed = true
    @socket?.end()
    wasOpen = @socket?
    @remote = null
    @socket = null
    @onDisconnect() if wasOpen

  onConnect: ->
    async.forEach @getFreeWorkers(), (worker, callback) =>
      @remote.registerWorker worker.toRPC(), callback
    , @errorCallback
    @setupEvents() if @subscribed
    @emit 'connect'

  onDisconnect: ->
    for id, stream of @activeStreams
      stream.emit 'error', new Error 'Lost connection.'
    @activeStreams = {}
    @emit 'disconnect'

  setupEvents: ->
    @eventStream = @multiplex.createStream 'events'
    @eventStream.on 'data', (data) =>
      try
        event = JSON.parse data
      catch error
        error.message = "Unable to parse event stream: #{ error.message }"
        @emit 'error', error
        return
      if @listenerCount(event.event) > 0
        [type] = event.event.split ' '
        if type is 'task' and @listenerCount event.event
          [task, extra...] = event.args
          task = Task.fromRPC task
          task.client = this
          @emit event.event, task, extra...
        else
          @emit event.event, event.args...
      if @eventProxy?
        @eventProxy.write event
      return

  getEventStream: ->
    unless @eventProxy?
      @eventProxy = new PassThrough {objectMode: true}
    unless @subscribed
      @subscribed = true
      @setupEvents() if @remote?
    return @eventProxy

  onError: (error) => @emit 'error', error

  errorCallback: (error) => @onError error if error?

  on: (event, handler) ->
    if event[...4] is 'task' and not @subscribed
      @subscribed = true
      @setupEvents() if @remote?
    super event, handler

  getQueue: (name) ->
    unless @queues[name]?
      @queues[name] = new ClientQueue name, this
    return @queues[name]

  addTask: (task, callback=@errorCallback) ->
    task.client = this
    unless @remote?
      @once 'connect', => @addTask task, callback
      return
    streams = @encodeStreams task.data
    async.forEach streams, (stream, callback) =>
      callbackOnce = (error) =>
        delete @activeStreams[stream.id]
        if callback?
          callback error
          callback = null
      destination = @multiplex.createStream 'write:' + stream.id
      @activeStreams[stream.id] = stream.value
      stream.value.on 'error', callbackOnce
      stream.value.on 'end', callbackOnce
      stream.value.resume?()
      stream.value.pipe destination
    , (error) =>
      if error?
        callback error
      else
        @remote.addTask task.toRPC(true), callback

  removeTask: (task, callback=@errorCallback) ->
    unless @remote?
      @once 'connect', => @removeTask task, callback
      return
    @remote.removeTask task.toRPC(), callback

  retryTask: (task, callback=@errorCallback) ->
    unless @remote?
      @once 'connect', => @retryTask task, callback
      return
    @remote.retryTask task.toRPC(), callback

  getTaskData: (task, callback) ->
    unless @remote?
      @once 'connect', => @getTaskData task, callback
      return
    if task.data?
      @resolveStreams task.data # TODO: don't mutate data
      callback null, task.data
    else
      @remote.getTaskData task.toRPC(), (error, data) =>
        unless error?
          @resolveStreams data
        callback error, data

  resolveStreams: (data) ->
    streams = []
    walk = (d) =>
      for key, value of d
        if value?.__stream?
          id = value.__stream
          stream = @multiplex.createStream 'read:' + id
          @activeStreams[id] = stream
          stream.on 'error', => delete @activeStreams[id]
          stream.on 'end', => delete @activeStreams[id]
          d[key] = stream
          streams.push stream
        else if typeof value is 'object'
          walk value
      return
    walk data
    return streams

  encodeStreams: (data) ->
    streams = []
    do walk = (data) ->
      for key, value of data
        if isStream value
          id = randomString 24
          data[key] = {__stream: id}
          streams.push {id, value}
        else if typeof value is 'object'
          walk value
      return
    return streams

  addWorker: (worker) ->
    unless @remote?
      @once 'connect', => @addWorker worker
      return
    worker.client = this
    @workers.push worker
    do register = => @remote?.registerWorker worker.toRPC()
    worker.on 'start', (task) =>
      task.on 'local-progress', (percent) =>
        @remote?.taskProgress task.toRPC(), percent
      task.once 'local-success', =>
        @taskSuccessful task
      task.once 'local-failure', (error) =>
        @taskFailure task, error
    worker.on 'finish', register

  taskSuccessful: (task, callback=@errorCallback) ->
    unless @remote?
      @once 'connect', => @taskSuccessful task, callback
      return
    @remote.taskSuccessful task.toRPC(), callback

  taskFailure: (task, error, callback=@errorCallback) ->
    unless @remote?
      @once 'connect', => @taskFailure task, error
      return
    @remote.taskFailure task.toRPC(), error, callback

  getFreeWorkers: -> @workers.filter (worker) -> worker.isFree()

  queue: (name) -> @getQueue name

  listTasks: (queue, filter, callback) ->
    unless @remote?
      @once 'connect', => @listTasks queue, filter, callback
      return
    @remote.listTasks queue, filter, (error, tasks) =>
      unless error?
        tasks = tasks.map (task) =>
          rv = Task.fromRPC task
          rv.client = this
          return rv
      callback error, tasks

  listQueues: (callback) ->
    unless @remote?
      @once 'connect', => @listQueues callback
      return
    @remote.listQueues (error, result) =>
      unless error?
        queues = result.map (name) => @getQueue name
      callback error, queues

class ClientQueue
  ### Convenience. ###

  constructor: (@name, @client) ->

  all: (callback) -> @client.listTasks @name, 'all', callback

  waiting: (callback) -> @client.listTasks @name, 'waiting', callback

  active: (callback) -> @client.listTasks @name, 'active', callback

  completed: (callback) -> @client.listTasks @name, 'completed', callback

  failed: (callback) -> @client.listTasks @name, 'failed', callback

  on: (event, handler) ->
    @client.on event, (task, args...) =>
      if task.queue is @name
        handler task, args...

  process: (processFn) ->
    worker = Worker.create @name, processFn
    @client.addWorker worker
    return worker

  add: (data, options, callback) ->
    if arguments.length is 2 and typeof options is 'function'
      callback = options
      options = null
    options ?= {}
    task = Task.create @name, options, data
    @client.addTask task, callback
    return task


module.exports = {Client}
