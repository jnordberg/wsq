
PATH  := node_modules/.bin:$(PATH)
SHELL := /bin/bash

.PHONY: test
test: node_modules
	@mocha --compilers coffee:coffee-script/register test

.PHONY: coverage
coverage: node_modules
	@mocha --compilers coffee:coffee-script/register --require test/coverage.js test/*.coffee
	@istanbul report html
	@open coverage/index.html

.PHONY: client
client: node_modules
	browserify -t coffeeify --extension .coffee -s wsq -o dist/client.js src/client.coffee

node_modules:
	npm install

.PHONY: clean
clean:
	rm -rf node_modules
	rm -rf lib
	rm -rf coverage

