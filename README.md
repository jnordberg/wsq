
# wsq [![Build Status](https://travis-ci.org/jnordberg/wsq.svg)](https://travis-ci.org/jnordberg/wsq) [![Coverage Status](https://coveralls.io/repos/jnordberg/wsq/badge.svg?branch=master&service=github)](https://coveralls.io/github/jnordberg/wsq?branch=master) [![Package Version](https://img.shields.io/npm/v/wsq.svg)](https://www.npmjs.com/package/wsq) ![License](https://img.shields.io/npm/l/wsq.svg)

Websocket task queue


What is it?
-----------

An easy to use task queue that handles streaming data, also works in the browser.


Example
-------

Video encoding

server.js (see [wsq-server](https://github.com/jnordberg/wsq-server) for a standalone server with logging)
```javascript
var Server = require('wsq/server')
var leveldown = require('leveldown')
var BlobStore = require('fs-blob-store')

new WsqServer({
  socketOptions: {port: 4242},
  dbLocation: '/var/leveldb/wsq',
  dbOptions: {db: leveldown}, // db can be any 'abstract-leveldown' compatible instance
  blobStore: new BlobStore('/var/storage/wsq') // same here any 'abstract-blob-store' will do
})
```

add.js:
```javascript
// usage: node add.js <videofile> <ffmpeg arguments>

var Client = require('wsq/client')
var fs = require('fs')

var client = new Client('ws://localhost:4242')
var queue = client.queue('ffmpeg')

var data = {
	video: fs.createReadStream(process.argv[2]),
	args: process.argv.slice(3)
}

var task = queue.add(data, function(error){
	if (error) {
		console.log('Error queueing video: ' + error.message)
		process.exit(1)
	} else {
		console.log('Video queued for processing.')
		process.exit()
	}
})

```

worker.js:
```javascript
var Client = require('wsq/client')
var fs = require('fs')
var os = require('os')
var path = require('path')

var client = new Client('ws://localhost:4242')

var videoQueue = client.queue('ffmpeg')
var resultQueue = client.quueu('ffmpeg-results')

videoQueue.process(function(task, callback) {
	var encoder = new VideoEncoder(task.data.args)

	encoder.on('progress', function(percent) {
		// update task progress, this will also reset the task timeout (default 60 seconds)
		// useful for long running tasks like this one
		task.updateProgress(percent)
	})

	// start encoding
	task.data.video.pipe(encoder)

	// start streaming the encoded video to the result queue, if the stream emits an error
	// the result task will not be created and any partial data streamed is discarded
	resultQueue.add({video: encoder}, function(error){
		if (error) {
			console.log('Encoding failed: ' + error.message)
			callback(error) // task is marked as failed, and possibly re-queued based on its options
		} else {
			// all good, ready to accept next task
			callback()
		}
	})
})
```


Documentation
-------------

### Class: Client

This class is a wsq client. It is an `EventEmitter`.

#### new Client(address, [options])

* `address` String
* `options` Object
  * `backoff` Function

Construct a new client object.

#### address

Address to wsq server, e.g. `'ws://localhost:1324'`

#### options.backoff

Function with the signature `function(tries){}` that should return number of milliseconds
to wait until next conneciton attempt.

The default funciton looks like:

```javascript
function(tries){
	return Math.min(Math.pow(tries * 10, 2), 60 * 1000)
}
```

#### client.queue(name)

Return a `ClientQueue` instance. Will be created if nonexistent.

#### client.listQueues()

Return an array of active `ClientQueue` instances.

#### client.getEventStream()

Return a object stream that writes all the events as they come in from the server.

```json
{
	"event": "<event name>",
	"args": [..]
}
```

#### Event: 'error'

`function(error){}`

#### Event: 'connect'

`function(){}`

Connected to server.

#### Event: 'disconnect'

`function(){}`

Connection was lost.


### Class: ClientQueue

This class is the client's representation of a queue. It is an `EventEmitter`.

#### queue.add(data, [options], [callback])

Add a task to the queue. The optional callback is called when the task is successfully added queued
or with an `Error` object on failure.

* `options` Object
  * `timeout` Number - Default `60 * 1000`
  * `retries` Number - Default `0`
  * `autoremove` Boolean - Default `false`

#### options.timeout

How long to wait for the task to complete without hearing from the worker in milliseconds.
Set to -1 to disable timeout (not recommended, use progress updates for long running tasks instead)

#### options.retries

How many times the task should be re-queued on failure. A value of zero
means no retries before the task have to be re-queued or removed explicitly.
Can also be set to -1 to retry forever.

#### options.autoremove

Wether to remove the task and any associated streams that where buffered on completion.
Note that failed tasks will always have to be handled explicitly.

#### queue.process(workerFn)

Add a worker to the queue. `workerFn` has the signature `function(task, callback){}`.

The callback should be called when the worker has completed processing the
task, or with an `Error` object on failure.

#### queue.all(callback)

Callback with a list of all `Task` instances in the queue.

#### queue.waiting(callback)

Callback with a list of all waiting `Task` instances in the queue.

#### queue.active(callback)

Callback with a list of all active `Task` instances in the queue.

#### queue.completed(callback)

Callback with a list of all completed `Task` instances in the queue.

#### queue.failed(callback)

Callback with a list of all failed `Task` instances in the queue.

#### Event: 'worker added'

`function(worker){}`

Worker was added to the queue.

#### Event: 'worker removed'

`function(worker){}`

Worker was removed from the queue.

#### Event: 'worker started'

`function(worker, task){}`

Worker started processing task.

#### Event: 'task <task_event>'

See `Task` events.


### Class: Task

This class represents a task. It is an `EventEmitter`.


#### task.updateProgress(percentage)

Update the progress of the task. Percentage is a fraction between 0 and 1.
Calling this resets the task timeout timer.

#### task.touch()

Reset the task timeout. Useful if your task process does not have any useful progress information
but you still want to keep long living tasks running.

#### task.remove(callback)

Remove the task from the system. Do not call this from inside a worker.

#### task.retry(callback)

Reschedule a failed task. Do not call this from inside a worker.

#### task.getData(callback)

Return task data with streams resolved. Note that `task.data` will already be resolved for tasks
passed to a worker.

#### Event: 'added'

`function(task){}`

Added to queue.

#### Event: 'queued'

`function(task){}`

Queued for processing.

#### Event: 'started'

`function(task){}`

Started processing.

#### Event: 'progress'

`function(task, percentage){}`

Progress updated. Percentage is a fraction between 0 and 1.

#### Event: 'completed'

`function(task){}`

Successfully processed.

#### Event: 'failed'

`function(task, willRetry){}`

Task failed, `task.error` will contain the failure message. `willRetry` is true if the task will be retried.

#### Event: 'deleted'

`function(task){}`

Task and associated streams was removed from the queue.


License
-------

MIT
