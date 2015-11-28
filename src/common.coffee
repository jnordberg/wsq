### Common utils shared between client and server. ###

crypto = require 'crypto'

urlsafeCharset = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_'

randomString = (length=32, charset=urlsafeCharset) ->
  rv = ''
  clen = charset.length
  for byte in crypto.randomBytes length
    rv += charset.charAt byte % clen
  return rv

module.exports = {
  randomString
  urlsafeCharset
}
