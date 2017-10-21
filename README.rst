kgk
===

A Discord image bot.

How to use it
*************

Copy *local.template.yml* to *local.yml*. Here's the meaning of the options:

- *token*: Discord bot token goes here.
- *roles*: This is a list of roles whose users can add and remove images and tags.
- *redis*: Here lie the Redis configuration options.

If you're deploying to Heroku, then uncomment the *env_url* line and comment out the
*host*, *password*

Then run ``./kgk.py local.yml`` to start the bot. You'll need a Redis instance running whose
settings you've filled out in your *local.yml* file.

Using docker-compose
********************

You can instead copy *redis.template.env* to *redis.env*, modify it to set a password,
and then make *local.yml* look like this:

.. code-block:: yaml

  redis:
    host: redis
    port: 6379
    password: REDIS_PASSWORD_HERE

putting the Redis password you set in *redis.env* here. Then just run
*docker-compose up --build*.

Using Heroku
************

Uncomment the *env_url* line in *local.yml*, and make sure you have a Heroku Redis plugin
available.
