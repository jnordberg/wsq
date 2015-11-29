
# wsq [![Build Status](https://travis-ci.org/jnordberg/wsq.svg)](https://travis-ci.org/jnordberg/wsq) [![Coverage Status](https://coveralls.io/repos/jnordberg/wsq/badge.svg?branch=master&service=github)](https://coveralls.io/github/jnordberg/wsq?branch=master) [![Package Version](https://img.shields.io/npm/v/wsq.svg)](https://www.npmjs.com/package/wsq) ![License](https://img.shields.io/npm/l/wsq.svg)

Websocket task queue


What is it?
-----------

An easy to use task queue that handles streaming data, also works in the browser.


What is it *not*?
-----------------

Real-time disruptive decentralized webscale 10 million ops per second message queue.


Example
-------

Video encoding

server.js:
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

queue.add(data, function(error){
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
// usage: node add.js <videofile> <ffmpeg arguments>

var Client = require('wsq/client')
var fs = require('fs')
var os = require('os')
var path = require('path')

var client = new Client('ws://localhost:4242')

var videoQueue = client.queue('ffmpeg')
var resultQueue = client.quueu('ffmpg-results')

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

Use the source luke.


License
-------

MIT
