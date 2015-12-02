### Server implementation. ###

async = require 'async'
dnode = require 'dnode'
levelup = require 'levelup'
multiplex = require 'multiplex'
through = require 'through'
WebSocket = require 'websocket-stream'
{EventEmitter} = require 'events'
{randomString} = require './common'
{Task} = require './task'

resolveStreamIds = (data) ->
  rv = []
  do walk = (data) =>
    for key, value of data
      if value.__stream?
        rv.push value.__stream
      else if typeof value is 'object'
        walk value
    return
  return rv

class Server extends EventEmitter

  defaults =

    workerTimeout: 1000 # 1 second
    # How long to wait for workers to respond when assigning a new task.

    # dbLocation - string, required
    # Location of database on disk, passed to levelup.

    dbOptions: {}
    # Database options given to levelup. See https://github.com/Level/levelup#options
    # Note that keyEncoding and valueEncoding will be overwritten if present.

    # socketOptions - object, required
    # Options passed to ws, see:
    # https://github.com/websockets/ws/blob/master/doc/ws.md#new-wsserveroptions-callback

    # blobStore - blob store instance, required
    # Blob store instance complying to the "abstract-blob-store" interface, see:
    # https://github.com/maxogden/abstract-blob-store

    heartbeatInterval: 1000 # 1 second
    # How often to ping clients to keep the connection alive. Set to zero to disable.

  requiredOptions = ['dbLocation', 'socketOptions', 'blobStore']

  constructor: (options) ->
    ### Create new queue server with *options*. ###

    unless options?
      throw new Error 'Missing options'

    for key in requiredOptions
      unless options[key]?
        throw new Error "Missing options.#{ key }"

    @options = {}
    for key of defaults
      @options[key] = options[key] ? defaults[key]

    @options.dbOptions.keyEncoding = 'utf8'
    @options.dbOptions.valueEncoding = 'json'

    @store = options.blobStore
    @database = levelup options.dbLocation, @options.dbOptions

    @queues = {}
    @connections = {}

    @eventStream = through()

    @restoreQueues =>
      @socketServer = new WebSocket.Server options.socketOptions
      @socketServer.on 'stream', @handleConnection
      @emit 'ready'

  close: ->
    @socketServer.close()

  broadcastEvent: (event, args...) ->
    @emit event, args...
    @eventStream.write JSON.stringify {event, args}

  handleConnection: (stream) =>
    connection = new Connection stream, this
    connection.id = randomString 24
    @connections[connection.id] = connection
    connection.on 'close', => delete @connections[connection.id]
    @emit 'connection', connection

  getQueue: (name) ->
    unless @queues[name]?
      @queues[name] = new Queue name, this
    return @queues[name]

  restoreQueues: (callback) ->
    restoreTask = (data) =>
      task = Task.fromDB data.value
      queue = @getQueue task.queue
      switch task.state
        when 'waiting'
          queue.waiting.push task
        when 'active'
          queue.active[task.id] = task
          queue.taskTimer task
        when 'failed'
          queue.failed.push task
        when 'completed'
          queue.completed.push task
        else
          @emit 'error', new Error "Encountered task with invalid state '#{ task.state }' in database."
    stream = @database.createReadStream()
    stream.on 'data', restoreTask
    stream.on 'error', (error) => @emit 'error', error
    stream.on 'end', callback

class Queue extends EventEmitter

  constructor: (@name, @server) ->
    @workers = []
    @waiting = []
    @completed = []
    @failed = []
    @active = {}
    @timers = {}

  addWorker: (worker) ->
    @workers.push worker
    @server.broadcastEvent 'worker added', {id: worker.id, connection: worker.connection}
    setImmediate @process

  removeWorker: (workerId) ->
    @workers = @workers.filter (worker) =>
      if worker.id is workerId
        @server.broadcastEvent 'worker removed', {id: worker.id, connection: worker.connection}
        return false
      return true

  removeTask: (task, callback) ->
    if @active[task.id]?
      clearTimeout @timers[task.id]
      task = @active[task.id]
      delete @active[task.id]
    else
      matchFilter = (t) ->
        if t.id is task.id
          task = t
          return false
        return true
      @failed = @failed.filter matchFilter
      @completed = @completed.filter matchFilter
      @waiting = @waiting.filter matchFilter
    @delTask task, callback

  emitError: (error) ->
    if error?
      @emit 'error', error

  getActive: ->
    tasks = []
    for id, task of @active
      tasks.push task
    return tasks

  getWaiting: -> @waiting

  getFailed: -> @failed

  getCompleted: -> @completed

  getAll: ->
    tasks = @getActive()
    tasks = tasks.concat @getWaiting()
    tasks = tasks.concat @getFailed()
    tasks = tasks.concat @getCompleted()
    return tasks

  putTask: (task, callback=@emitError) ->
    @server.database.put task.id, task.toDB(), callback

  delTask: (task, callback=@emitError) ->
    removeBlob = (key, callback) => @server.store.remove {key}, callback
    removeAllBlobs = (callback) =>
      ids = resolveStreamIds task.data
      async.forEach ids, removeBlob, callback
    deleteTask = (callback) => @server.database.del task.id, callback
    broadcast = (callback) =>
      @server.broadcastEvent 'task deleted', task.toRPC()
      callback()
    async.series [removeAllBlobs, deleteTask, broadcast], callback

  addTask: (task, callback=@emitError) ->
    task.state = 'waiting'
    @putTask task, (error) =>
      if error?
        @emit 'error', error
      else
        @waiting.push task
        @server.broadcastEvent 'task added', task.toRPC()
        @server.broadcastEvent 'task queued', task.toRPC()
        setImmediate => @process()
      callback error

  sanityCheck: (method, task) ->
    unless @active[task.id]?
      @emit 'error', new Error "#{ method } - Task #{ task.id } not active"
      return false
    activeWorker = @active[task.id].workerId
    if activeWorker isnt task.workerId
      @emit 'error', new Error "#{ method } - Wrong worker, got #{ task.workerId } expected #{ activeWorker }"
      return false
    return true

  taskComplete: (task) ->
    return unless @sanityCheck 'complete', task
    task = @active[task.id]
    clearTimeout @timers[task.id]
    delete @active[task.id]
    task.state = 'completed'
    @server.broadcastEvent 'task completed', task.toRPC()
    if task.options.autoremove
      @delTask task
    else
      @putTask task
      @completed.push task

  taskFailure: (task, error) ->
    return unless @sanityCheck 'failure', task
    task = @active[task.id]
    clearTimeout @timers[task.id]
    delete @active[task.id]
    task.state = 'failed'
    task.error = error.message
    @server.broadcastEvent 'task failed', task.toRPC()
    if ++task.retries > task.options.retries and task.options.retries isnt -1
      @failed.push task
    else
      task.state = 'waiting'
      task.error = null
      @server.broadcastEvent 'task queued', task.toRPC()
      @waiting.push task
      setImmediate => @process()
    @putTask task

  taskProgress: (task, percent) ->
    return unless @sanityCheck 'progress', task
    @active[task.id].progress = percent
    @putTask @active[task.id]
    @server.broadcastEvent 'task progress', task.toRPC(), percent
    @taskTimer task

  taskTimer: (task) ->
    unless task = @active[task.id]
      @emit 'error', new Error 'Task not active.'
      return
    if task.options.timeout isnt -1
      timeout = =>
        error = new Error 'Timed out.'
        task._worker?.abort?()
        @taskFailure task, error
      clearTimeout @timers[task.id]
      @timers[task.id] = setTimeout timeout, task.options.timeout

  process: =>
    canProcess = => @workers.length > 0 and @waiting.length > 0
    startTask = (callback) =>
      worker = @workers.shift()
      task = @waiting.shift()

      timedOut = =>
        error = new Error "Worker #{ worker.id } didn't respond."
        @taskFailure task, error
        callback()
        callback = null # ignore late responses by worker

      task.workerId = worker.id
      task.state = 'active'
      task.progress = 0
      task._worker = worker
      @active[task.id] = task
      @server.broadcastEvent 'task started', task.toRPC()

      @putTask task, (error) =>
        return callback error if error?
        timer = setTimeout timedOut, @server.options.workerTimeout
        worker.start task.toRPC(true), (error) =>
          return unless callback?
          @server.broadcastEvent 'worker started', {id: worker.id, connection: worker.connection}, task.toRPC()
          clearTimeout timer
          if error?
            @taskFailure task, error
          else
            @taskTimer task
          callback()

    async.whilst canProcess, startTask, @emitError


class Connection extends EventEmitter

  RPC_METHODS = [
    'addTask'
    'removeTask'
    'listTasks'
    'listQueues'
    'registerWorker'
    'taskFailure'
    'taskProgress'
    'taskSuccessful'
  ]

  constructor: (@stream, @server) ->
    @seenWorkers = {}
    # setup multiplex stream
    @multiplex = multiplex @handleStream.bind(this)
    @stream.pipe(@multiplex).pipe(@stream)
    @stream.on 'error', @onError
    @stream.on 'end', @onEnd
    # setup rpc stream via multiplex
    rpcStream = @multiplex.createSharedStream 'rpc'
    @rpc = dnode @getRpcMethods(), {weak: false}
    @rpc.pipe(rpcStream).pipe(@rpc)
    if @server.options.heartbeatInterval > 0
      @pingCounter = 0
      @stream.socket.on 'pong', => @pingCounter = 0
      @heartbeatTimer = setInterval @heartbeat, @server.options.heartbeatInterval
      @heartbeat()

  onError: (error) =>
    @cleanup()
    @emit 'error', error
    @emit 'close'

  onEnd: =>
    @cleanup()
    @emit 'close'

  cleanup: ->
    clearTimeout @heartbeatTimer
    for workerId, queueName of @seenWorkers
      @server.getQueue(queueName).removeWorker(workerId)

  heartbeat: =>
    if @pingCounter >= 2
      @stream.end()
    else
      @stream.socket.ping()
      @pingCounter++

  getRpcMethods: ->
    rv = {}
    for methodName in RPC_METHODS
      rv[methodName] = this[methodName].bind(this)
    return rv

  handleStream: (stream, id) =>
    [type, id] = id.split ':'
    switch type
      when 'write'
        destination = @server.store.createWriteStream id
        stream.pipe destination
      when 'read'
        source = @server.store.createReadStream id
        stream.on 'error', -> # discard, handled by client
        source.on 'error', (error) -> stream.destroy error
        source.pipe stream
      when 'events'
        @server.eventStream.pipe stream
      else
        @emit 'error', new Error "Can't handle stream type #{ type }"

  registerWorker: (worker) ->
    @seenWorkers[worker.id] = worker.queue
    queue = @server.getQueue worker.queue
    worker.connection = @id
    queue.addWorker worker

  taskSuccessful: (task) ->
    task = Task.fromRPC task
    queue = @server.getQueue task.queue
    queue.taskComplete task

  taskProgress: (task, percent) ->
    task = Task.fromRPC task
    queue = @server.getQueue task.queue
    queue.taskProgress task, percent

  taskFailure: (task, error) ->
    task = Task.fromRPC task
    queue = @server.getQueue task.queue
    queue.taskFailure task, error

  addTask: (task, callback) ->
    task = Task.fromRPC task
    queue = @server.getQueue task.queue
    queue.addTask task, callback

  removeTask: (task, callback) ->
    task = Task.fromRPC task
    queue = @server.getQueue task.queue
    queue.removeTask task, callback

  listTasks: (queue, filter, callback) ->
    queue = @server.getQueue queue
    switch filter
      when 'all', null
        tasks = queue.getAll()
      when 'failed'
        tasks = queue.getFailed()
      when 'completed'
        tasks = queue.getCompleted()
      when 'waiting'
        tasks = queue.getWaiting()
      when 'active'
        tasks = queue.getActive()
      else
        callback new Error "Unknown filter: #{ filter }"
        return
    callback null, tasks.map (task) -> task.toRPC()

  listQueues: (callback) ->
    callback null, Object.keys @server.queues


module.exports = {Server}