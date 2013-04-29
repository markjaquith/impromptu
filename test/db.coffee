should = require 'should'
Impromptu = require '../src/impromptu'
fs = require 'fs'
redis = require 'redis'
async = require 'async'
exec = require('child_process').exec

# Skip the database tests on Travis CI
# Todo: Make these work
return if process.env.TRAVIS is 'true'

Impromptu.DB.REDIS_PORT = 6421
Impromptu.DB.REDIS_CONF_FILE = '../test/etc/redis.conf'
Impromptu.DB.REDIS_PID_FILE = '/usr/local/var/run/redis-impromptu-test.pid'

describe 'Database', ->
  # Try to kill the server if it's running.
  before (done) ->
    # Check if the server is running.
    path = Impromptu.DB.REDIS_PID_FILE
    return done() unless fs.existsSync path

    # Fetch the process ID and kill it.
    pid = parseInt fs.readFileSync(path), 10
    # Make it die a painful death.
    exec "kill -9 #{pid}", done

  it 'should exist', ->
    should.exist Impromptu.DB

  it 'should be stopped', (done) ->
    client = redis.createClient Impromptu.DB.REDIS_PORT

    client.on 'error', ->
      client.quit()
      done()

    client.on 'connect', ->
      client.quit()
      done new Error 'Database connected.'

    client.on 'reconnecting', ->
      client.removeAllListeners()

  it 'should start', (done) ->
    db = new Impromptu.DB
    client = db.client()
    client.on 'connect', ->
      client.quit()
      done()

    client.once 'error', ->
      # On the first error, the client will try to spawn the server.
      # If it encounters another error, it failed.
      client.once 'error', ->
        client.quit()
        done new Error 'Database did not connect.'

      client.on 'reconnecting', ->
        client.removeAllListeners

  it 'should stop', (done) ->
    db = new Impromptu.DB
    db.client().on 'end', done
    db.shutdown()


describe 'Cache', ->
  impromptu = new Impromptu()
  background = new Impromptu
    background: true

  before (done) ->
    async.series [
      (fn) ->
        impromptu.db.client().on 'connect', fn
      (fn) ->
        impromptu.db.client().flushdb fn
      (fn) ->
        background.db.client().on 'connect', fn
    ], done

  it 'should create an instance', ->
    method = new Impromptu.Cache impromptu, 'method',
      update: (fn) ->
        fn null, 'value'

    should.exist method

  it 'should be null on first miss', (done) ->
    cached = new Impromptu.Cache impromptu, 'missing',
      update: (fn) ->
        should.fail 'Update should not run.'
        fn null, 'value'

    cached.run (err, value) ->
      should.not.exist value
      done()

  it 'should update when background is set', (done) ->
    cached = new Impromptu.Cache background, 'should-update',
      update: (fn) ->
        done()
        fn null, 'value'

    cached.run()

  it 'should fetch cached values', (done) ->
    updater = new Impromptu.Cache background, 'should-fetch',
      update: (fn) ->
        fn null, 'value'

    fetcher = new Impromptu.Cache impromptu, 'should-fetch',
      update: (fn) ->
        should.fail 'Update should not run.'
        fn null, 'value'

    async.series [
      (fn) ->
        fetcher.run (err, fetched) ->
          should.not.exist fetched
          fn err

      (fn) ->
        updater.run (err, updated) ->
          updated.should.equal 'value'
          fn err

      (fn) ->
        fetcher.run (err, fetched) ->
          fetched.should.equal 'value'
          fn err
    ], done

  it 'should clear cached values', (done) ->
    updater = new Impromptu.Cache background, 'should-clear',
      update: (fn) ->
        fn null, 'value'

    async.series [
      (fn) ->
        updater.get (err, result) ->
          should.not.exist result
          fn err

      (fn) ->
        updater.set (err, result) ->
          result.should.equal true
          fn err

      (fn) ->
        updater.get (err, result) ->
          result.should.equal 'value'
          fn err

      (fn) ->
        updater.unset (err, result) ->
          result.should.equal true
          fn err

      (fn) ->
        updater.get (err, result) ->
          should.not.exist result
          fn err

    ], done
