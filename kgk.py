#!/usr/bin/env python36

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.


import discord, hashlib, json, lxml, random, re, redis, requests
from contextlib import contextmanager
from bs4 import BeautifulSoup
import zdiscord

import asyncio, sys


class Config(zdiscord.Config):
    DEFAULT_PATH = '~/.kgk.yml'


class KGKCommands:
    _TAG_RE = re.compile(r'[a-zA-Z0-9_]+$')
    _IMG_RE = re.compile(r'https://i.pingimg.com/(\d+)x/')


    def __init__(self, bot):
        self.bot = bot
        self.logger = self.bot.logger
        self.r = redis.StrictRedis(host=self.bot.config.redis['host'],
                                   port=int(self.bot.config.redis['port']),
                                   db=0)


    async def get_pinterest_image(self, url):
        resp = requests.get(url)
        html = BeautifulSoup(resp.content, 'lxml')
        self.logger.info(resp.content)

        current_size = 0
        current_url = None
        for script in html.find_all('script', type='application/json'):
            tree = json.loads(script.string)
            meta = tree['initialPageInfo']['meta']
            return meta['twitter:image:src']

        await self.bot.say(
            "I couldn't find any pictures at that Pinterest URL... :thinking:")


    async def get_url(self, url):
        if url.startswith('https://pinterest.') or \
           url.startswith('https://www.pinterest.'):
            self.logger.info('detected pinterest url')
            url = await self.get_pinterest_image(url)

        if url is None:
            return None, None

        return url, hashlib.blake2s(url.encode('utf-8')).hexdigest()


    async def get_image(self, url):
        bhashed = self.r.hget('images:byurl', url)
        if bhashed is None:
            await self.bot.say("I don't have this image saved!!")
            return
        return bhashed.decode('utf-8')


    async def check_user(self, ctx):
        required_roles = set(role.lower() for role in self.bot.config.roles)
        used_roles =  set(role.name.lower() for role in ctx.message.author.roles)

        if required_roles & used_roles:
            return True
        else:
            await self.bot.say("Sorry, you don't have permission to do that. :shrug:")
            return False


    async def verify_tags(self, tags):
        for tag in tags:
            if not self._TAG_RE.match(tag):
                self.logger.error(f'invalid tag: {tag}')
                await self.bot.say(f'invalid tag: {tag}')
                return False
        return True


    @zdiscord.safe_command
    async def add(self, ctx, url, *tags):
        '''
        Adds an image.

        Example usage:
        .add https://my-image-url.com/ tag1 tag2
        '''

        self.logger.info(f'addimage {url} {tags}')

        if not await self.check_user(ctx) or not await self.verify_tags(tags):
            return

        url, hashed = await self.get_url(url)
        if url is None:
            return

        with self.r.pipeline() as p:
            p.sadd('images', hashed)
            p.hset('images:byurl', url, hashed)
            p.hset('images:byhash', hashed, url)

            p.sadd(f'tags:{hashed}', *tags)
            for tag in tags:
                p.sadd(f'tag:{tag}', hashed)

            p.execute()

        await self.bot.say('Done!')


    @zdiscord.safe_command
    async def remove(self, ctx, url):
        '''
        Removes an image.

        Example usage:
        .remove myurl
        '''

        self.logger.info(f'remove {url}')

        if not await self.check_user(ctx):
            return

        hashed = await self.get_image(url)
        if hashed is None:
            return

        with self.r.pipeline() as p:
            while True:
                try:
                    p.watch(f'tags:{hashed}')
                    tags = p.smembers(f'tags:{hashed}')
                    p.multi()

                    p.srem('images', hashed)
                    p.hdel('images:byurl', url)
                    p.hdel('images:byhash', hashed)

                    p.delete(f'tags:{hashed}')
                    for tag in tags:
                        p.srem(f'tag:{tag}', hashed)

                    p.execute()
                except redis.WatchError:
                    self.logger.error('WatchError: trying again...')
                    continue
                else:
                    break

        await self.bot.say('Done!')


    @zdiscord.safe_command
    async def image(self, ctx, tag=None):
        '''
        Displays a random image. If a tag is given, then display an image with the given
        tag.

        Examples:
        .image      # <-- shows a random image
        .image xyz  # <-- shows a random image with tag 'xyz'
        '''

        self.logger.info(f'image {tag!r}')

        if not await self.check_user() or not self.verify_tags([tag]):
            return

        hashed = self.r.srandmember('images' if tag is None else f'tag:{tag}')
        url = self.r.hget('images:byhash', hashed)

        if url:
            await self.bot.say(url.decode('utf-8'))
        else:
            await self.bot.say(
                "Couldn't find any images...are you sure you have the right tag?")

    @zdiscord.safe_command
    async def tags(self, url=None):
        '''
        List all the defines tags. If an image is given, list the tags for that image.
        '''

        self.logger.info(f'tags {url!r}')

        if url is None:
            tags = [tag.replace(b'tag:', b'') for tag in self.r.keys('tag:*')]
        else:
            hashed = await self.get_image(url)
            if hashed is None:
                return

            tags = list(self.r.smembers(f'tags:{hashed}') or [])

        tags.sort()
        self.logger.info(f'tags: {tags}')

        res = ['```']
        for tag in tags:
            res.append(f' * {tag.decode("utf-8")}')
        res.append('```')

        await self.bot.say('\n'.join(res))


    @zdiscord.safe_command
    async def tag(self, ctx, url, *tags):
        '''
        Add tags to an image.

        Example:
        .tag url mytag  # <-- adds mytag to the image
        '''

        self.logger.info(f'tag {url} {tags}')

        if not await self.check_user(ctx) or not await self.verify_tags(tags):
            return

        hashed = await self.get_image(url)
        if hashed is None:
            return

        with self.r.pipeline() as p:
            p.sadd(f'tags:{hashed}', *tags)
            for tag in tags:
                p.sadd(f'tag:{tag}', hashed)

            p.execute()

        await self.bot.say('Done!')

    @zdiscord.safe_command
    async def untag(self, ctx, url, *tags):
        '''
        Remove the given tags from an image.

        Example:
        .untag url mytag  # <-- removes mytag fromt the image
        '''

        self.logger.info(f'untag {url} {tags}')

        if not await self.check_user(ctx) or not await self.verify_tags(tags):
            return

        hashed = await self.get_image(url)
        if hashed is None:
            return

        with self.r.pipeline() as p:
            p.srem(f'tags:{hashed}', *tags)
            for tag in tags:
                p.srem(f'tag:{tag}', hashed)

            p.execute()

        await self.bot.say('Done!')


class KGK(zdiscord.Bot):
    COMMAND_PREFIX = '.'
    COMMANDS = KGKCommands


def main():
    asyncio.set_event_loop(asyncio.new_event_loop())
    zdiscord.main(KGK, Config())


if __name__ == '__main__':
    main()
