### Shared task implementation. ###

assert = require 'assert'
{EventEmitter} = require 'events'
{randomString} = require './common'

DB_KEYS = [
  'data', 'id', 'options', 'progress', 'queue', 'retries', 'state', 'workerId', 'error'
]

class Task extends EventEmitter

  defaults =

    timeout: 60 * 1000 # 1 minute
    # How long to wait for the task to complete without hearing from the worker in milliseconds.
    # Set to -1 to disable timeout (not recommended, use progress updates for long running tasks instead)

    retries: 0
    # How many times the task should be re-queued on failure. A value of zero
    # means no retries before the task have to be re-queued or removed explicitly.
    # Can also be set to -1 to retry forever.

    autoremove: false
    # Wether to remove the task and any associated streams that where buffered on completion.
    # Note that failed tasks will always have to be handled explicitly.

  constructor: (@id, @queue, @data, options={}) ->
    ### Create new task with *@id* on *@queue* containing *@data*, see defaults for available *options*. ###
    @options = {}
    @retries = 0
    @progress = 0
    @state = 'unknown'
    @aborted = false
    @_listeners = {}
    for key of defaults
      @options[key] = options[key] ? defaults[key]

  updateProgress: (percent) ->
    ### Set task progress to *percent* expressed as a fraction between 0 and 1. ###
    @progress = percent
    @emit 'local-progress', percent

  touch: ->
    ### Send a progress update to server, refreshing the task timeout. Useful if you can't
        mesure progress but need to keep a long running task alive. ###
    @emit 'local-progress', @progress

  _isLocal: (event) -> event[...5] is 'local' or event is 'abort'

  _setupListener: (event) ->
    return if @_listeners[event]? or @_isLocal event
    assert @client?, 'No client assigned'
    @_listeners[event] = (task, extra...) =>
      if task.id is @id
        @emit event, task, extra...
      return
    @client.on "task #{ event }", @_listeners[event]

  on: (event, handler) ->
    @_setupListener event
    super event, handler

  once: (event, handler) ->
    @_setupListener event
    super event, handler

  remove: (callback) ->
    @client.removeTask this, callback

  retry: (callback) ->
    @client.retryTask this, callback

  getData: (callback) ->
    @client.getTaskData this, callback

  toRPC: (includeData=false) ->
    ### Private, used to serialize the task before it is sent over the wire. ###
    rv = {@id, @queue, @options, @retries, @state}
    rv.workerId = @workerId if @workerId?
    rv.error = @error if @error?
    rv.data = @data if includeData
    return rv

  toDB: ->
    ### Private, used to serialize the task before storing in database. ###
    rv = {}
    for key in DB_KEYS
      rv[key] = this[key]
    return rv

Task.create = (queue, options, data) ->
  ### Create new task on *queue* with *options* and *data*.  ###
  if arguments.length is 2
    data = options
    options = {}
  id = randomString 24
  return new Task id, queue, data, options

Task.fromRPC = (data) ->
  ### Private, deserialize task comming from rpc. ###
  task = new Task data.id, data.queue, data.data, data.options
  task.workerId = data.workerId if data.workerId?
  task.retries = data.retries if data.retries?
  task.error = data.error if data.error?
  task.state = data.state if data.state?
  return task

Task.fromDB = (data) ->
  ### Private, deserialize task comming from database. ###
  task = new Task
  for key in DB_KEYS
    task[key] = data[key]
  return task

module.exports = {Task}