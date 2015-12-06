
PATH  := node_modules/.bin:$(PATH)
SHELL := /bin/bash

.PHONY: test
test: node_modules
	@mocha --compilers coffee:coffee-script/register --bail test

.PHONY: coverage
coverage: node_modules
	@mocha --compilers coffee:coffee-script/register --require test/coverage.js test/*.coffee
	@istanbul report html
	@open coverage/index.html

.PHONY: client
client: node_modules
	browserify -t coffeeify --extension .coffee -s wsq -o dist/client.js src/client.coffee
	cat ./dist/client.js | uglifyjs > ./dist/client.min.js

node_modules:
	npm install

.PHONY: clean
clean:
	rm -rf node_modules
	rm -rf lib
	rm -rf coverage

.PHONY: publish
publish:
	@set -e ;\
	current_version=$$(node -e 'console.log(require("./package").version)') ;\
	read -r -p "New version (current $$current_version): " version ;\
	node -e "p=require('./package');p.version='$$version';console.log(JSON.stringify(p, null, 2))" > package_tmp.json ;\
	make client ;\
	while [ -z "$$really" ]; do \
		read -r -p "Publish as version $$version? [y/N]: " really ;\
	done ;\
	[ $$really = "y" ] || [ $$really = "Y" ] || (echo "Nevermind then."; exit 1;) ;\
	mv package_tmp.json package.json ;\
	git add dist/ package.json ;\
	git commit -m $$version ;\
	git tag $$version ;\
	npm publish
