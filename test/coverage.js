var path = require('path')
var coffeeCoverage = require('coffee-coverage')

coffeeCoverage.register({
    instrumentor: 'istanbul',
    basePath: path.resolve(__dirname, '..'),
    exclude: ['/test', '/node_modules', '/.git', '/examples', '/dist'],
    writeOnExit: 'coverage/coverage-coffee.json'
})