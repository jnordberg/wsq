
db = require 'memdown'
store = require 'abstract-blob-store'

{Client} = require './../src/client'
{Server} = require './../src/server'
{Worker} = require './../src/worker'

assert = require 'assert'
through = require 'through'

server = null
client = null

serverOpts =
  blobStore: new store()
  dbLocation: 'nowhere'
  dbOptions: {db}
  socketOptions: {}
  heartbeatInterval: 100
  workerTimeout: 100

makeServer = (port=4242) ->
  serverOpts.socketOptions.port = port
  new Server serverOpts

describe 'server', ->

  it 'throws without options', ->
    assert.throws -> server = new Server

  it 'throws with missing options', ->
    assert.throws -> server = new Server {}

  it 'starts', ->
    server = makeServer()
    server.on 'error', (error) -> assert.ifError error

  it 'should close stream if client does not respond to ping', (done) ->
    @slow 800
    cli = new Client 'ws://localhost:4242'
    cli.on 'connect', ->
      pongs = 0
      cli.socket.socket.pong = -> pongs++
      cli.on 'disconnect', ->
        assert.equal pongs, 2
        cli.close()
        done()

describe 'client', ->

  it 'connects', (done) ->
    client = new Client 'ws://localhost:4242'
    client.once 'connect', -> done()

  it 'reconnects', (done) ->
    server.close()
    client.once 'connect', -> done()
    server = makeServer()

  it 'closes', (done) ->
    client.once 'disconnect', -> done()
    client.close()

  it 'connects again', (done) ->
    client.connect()
    client.once 'connect', -> done()

  it 'throws if already connected', ->
    assert.throws -> client.connect()

  it 'should list active queues', (done) ->
    client.queue('listme').add {foo: 1}, (error) ->
      assert.ifError error
      client.listQueues (error, queues) ->
        assert.ifError error
        assert.equal queues.length, 1
        assert.equal queues[0].name, 'listme'
        done()

describe 'queue', ->

  it 'adds a task', (done) ->
    queue = client.queue 'test1'
    queue.add {foo: 'bar'}, (error) ->
      assert.ifError error
      done()

  it 'shows added task as waiting', (done) ->
    queue = client.queue 'test1'
    queue.waiting (error, tasks) ->
      assert.ifError error
      assert.equal tasks.length, 1
      done()

  it 'runs task when worker is added', (done) ->
    queue = client.queue 'test1'
    queue.process (task, callback) ->
      assert.deepEqual task.data, {foo: 'bar'}
      callback()
      done()

  it 'lists completed task', (done) ->
    queue = client.queue 'test1'
    queue.completed (error, tasks) ->
      assert.ifError error
      assert.equal tasks.length, 1
      assert.equal tasks[0].state, 'completed'
      done()

  it 'adds another task with different options', (done) ->
    queue = client.queue 'test2'
    queue.add {foo: 'bar'}, {timeout: 1234, retries: 1, autoremove: true}, (error) ->
      assert.ifError error
      done()

  it 'retries task on failure', (done) ->
    queue = client.queue 'test2'
    run = 0
    queue.process (task, callback) ->
      if ++run < 2
        error = new Error 'Task failed'
      callback error
      if run is 2
        done()

  it 'removes completed tasks with autoremove option set', (done) ->
    queue = client.queue 'test2'
    queue.completed (error, tasks) ->
      assert.ifError error
      assert.equal tasks.length, 0
      done()

  it 'adds another task with streams', (done) ->
    queue = client.queue 'test3'
    stream = through()
    setImmediate ->
      stream.write 'foobarz'
      stream.end()
    queue.add {foo: {stream}}, (error) ->
      assert.ifError error
      done()

  it 'runs streaming tasks', (done) ->
    queue = client.queue 'test3'
    queue.process (task, callback) ->
      assert task.data.foo.stream?
      task.data.foo.stream.on 'data', (data) ->
        assert.equal data.toString(), 'foobarz'
      task.data.foo.stream.on 'end', ->
        callback()
        done()

  it 'removes stored stream along with task', (done) ->
    queue = client.queue 'test3'
    queue.completed (error, tasks) ->
      assert.ifError error
      assert.equal tasks.length, 1
      task = tasks[0]
      task.remove (error) ->
        assert.ifError error
        queue.completed (error, tasks) ->
          assert.ifError error
          assert.equal tasks.length, 0
          assert.equal Object.keys(server.store.data).length, 0
          done()

  it 'does not add task if stream emits error', (done) ->
    queue = client.queue 'test3'
    stream = through()
    setImmediate ->
      stream.emit 'error', new Error 'Stream error'
    queue.add {some: {stream}}, (error) ->
      assert.ok error?
      assert.equal error.message, 'Stream error'
      queue.all (error, tasks) ->
        assert.ifError error
        assert.equal tasks.length, 0
        done()

  it 'adds task after reconnecting', (done) ->
    @slow 200
    queue = client.queue 'test4'
    client.close()
    queue.add {foo: 'bar'}, (error) ->
      assert.ifError error
      done()
    setImmediate -> client.connect()

  it 'fails added task', (done) ->
    queue = client.queue 'test4'
    queue.process (task, callback) ->
      assert.deepEqual task.data, {foo: 'bar'}
      callback new Error 'Fail'
      done()

  it 'lists failed task', (done) ->
    queue = client.queue 'test4'
    queue.failed (error, tasks) ->
      assert.ifError error
      assert.equal tasks.length, 1
      assert.equal tasks[0].state, 'failed'
      assert.equal tasks[0].error, 'Fail'
      done()

  it 'emits broadcast events', (done) ->
    queue = client.queue 'test5'
    queue.on 'task added', (task) ->
      assert.equal task.id, outerTask.id
      done()
    outerTask = queue.add {a: [1]}

  it 'handles disconnections when adding streams', (done) ->
    @slow 500
    srv2 = makeServer 5252
    cli2 = new Client 'ws://localhost:5252'
    cli2.on 'error', (error) ->
      assert.equal error.code, 'ECONNREFUSED'
    cli2.on 'connect', ->
      queue = cli2.queue 'test6'
      stream = through()
      t = setInterval (-> stream.write 'foo'), 2
      setTimeout (-> srv2.close()), 100
      queue.add {a: {b: stream}}, (error) ->
        assert.equal error.message, 'Lost connection.'
        clearTimeout t
        srv2.close()
        done()

  it 'handles disconnections when receiving streams', (done) ->
    @slow 300
    srv3 = makeServer 6262
    cli3 = new Client 'ws://localhost:6262'
    cli3.on 'error', (error) ->
      assert.equal error.code, 'ECONNREFUSED'

    stream = through()
    stream.pause()
    stream.queue 'foobar'
    stream.queue null

    queue = cli3.queue 'test6'
    task = queue.add {stream}, (error) -> assert.ifError error
    queue.process (task, callback) ->
      srv3.close()
      task.data.stream.on 'error', (error) ->
        assert.equal error.message, 'Lost connection.'
        cli3.close()
        done()

  it 'lists active tasks', (done) ->
    @slow 300
    cli = new Client 'ws://localhost:4242'
    queue = cli.queue 'test7'
    queue.add {foo: 'bar'}
    queue.process (task, callback) ->
      queue.active (error, tasks) ->
        assert.ifError error
        assert.equal tasks.length, 1
        callback()
        setTimeout ->
          cli.close()
          done()
        , 100

  it 'lists all tasks', (done) ->
    queue = client.queue 'test7'
    queue.add {foo: 'bar'}
    queue.all (error, tasks) ->
      assert.ifError error
      assert.equal tasks.length, 2
      done()

  it 'stops workers on timeout', (done) ->
    @slow 300
    queue = client.queue 'test8'
    task = queue.add {foo: 'bar'}, {timeout: 100}
    abortFired = false
    queue.process (task, callback) ->
      task.on 'abort', -> abortFired = true
      setTimeout callback, 200
    task.on 'failed', (task) ->
      assert.equal abortFired, true
      assert.equal task.error, 'Timed out.'
      done()

  it 'fails task if worker does not respond', (done) ->
    @slow 400
    queue = client.queue 'noresponse'
    worker = Worker.create 'noresponse', -> assert false, 'should not start processing'
    worker.start = ->
    client.addWorker worker
    task = queue.add {foo: 1}, (error) -> assert.ifError error
    task.on 'failed', (task) ->
      assert.equal task.error, "Worker #{ worker.id } didn't respond."
      done()

describe 'server persitence', ->

  it 'perists tasks', (done) ->
    server2 = makeServer 5252
    server2.once 'ready', ->
      queue = server.getQueue 'test1'
      assert.equal queue.getAll().length, 1
      server2.close()
      done()

describe 'task', ->

  it 'emits events', (done) ->
    queue = client.queue 'test9'
    task = queue.add {a: 1}
    task.on 'queued', -> done()

  it 'updates progress', (done) ->
    @slow 300
    queue = client.queue 'test9'
    sawProgress = false
    queue.waiting (error, tasks) ->
      assert.ifError error
      assert tasks.length, 1
      task = tasks[0]
      task.on 'progress', (task, progress) ->
        assert.equal progress, 0.5
        sawProgress = true
    cb = ->
      assert.ok sawProgress, 'should have seen progress'
      done()
    queue.process (task, callback) ->
      task.updateProgress 0.5
      setTimeout cb, 100
      setTimeout callback, 100

  it 'should retry', (done) ->
    @slow 200
    queue = client.queue 'test10'
    numCalls = 0
    queue.process (task, callback) ->
      if ++numCalls < 3
        error = new Error "Fail #{ numCalls }"
      callback error

    task = queue.add {foo: 1}, {retries: 1}, (error) -> assert.ifError error

    task.on 'completed', (task) ->
      assert.equal numCalls, 3
      assert.equal task.error, undefined
      done()

    task.on 'failed', (task, willRetry) ->
      if numCalls is 1
        assert willRetry, 'should retry'
        assert.equal task.retries, 1
      else if numCalls is 2
        assert !willRetry, 'should not retry'
        assert.equal task.retries, 2
        task.retry (error) -> assert.ifError error
      else
        assert false, 'unexpected failed event'
