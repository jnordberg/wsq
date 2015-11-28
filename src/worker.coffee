### Client worker implementation. ###

{EventEmitter} = require 'events'
{Task} = require './task'
{randomString} = require './common'

unless setImmediate?
  setImmediate = process.nextTick

class Worker extends EventEmitter

  constructor: (@id, @queue, @process) ->
    @activeTask = null

  start: (task, callback) =>
    ### Start processing *task*. This method is called by the server. ###
    if task not instanceof Task
      task = Task.fromRPC task
    if @activeTask?
      callback new Error 'Already running.'
      return
    if task.queue isnt @queue
      callback new Error 'Task queue mismatch.'
      return
    @activeTask = task
    task.workerId = @id
    @emit 'start', task
    setImmediate =>
      @client.resolveStreams task.data
      called = false
      @process task, (error) =>
        return if task.aborted
        throw new Error 'Worker callback called multiple times.' if called
        called = true
        @activeTask = null
        if error?
          task.emit 'local-failure', error
        else
          task.emit 'local-success'
        @emit 'finish', task
    callback()

  abort: =>
    ### Abort running task. Called by server if task has timed out or is manually aborted. ###
    return unless @activeTask?
    @activeTask.aborted = true
    @activeTask.state = 'failed'
    @activeTask.emit 'abort'
    @emit 'finish', @activeTask
    @activeTask = null

  isFree: -> not @activeTask?

  toRPC: -> {@id, @queue, @start, @abort}


Worker.create = (queue, processFn) ->
  new Worker randomString(24), queue, processFn


module.exports = {Worker}