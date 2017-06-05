#!/usr/bin/env python3
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import sys, os, os.path
import getpass
import subprocess
import argparse
import shutil

if sys.version_info <= (3, 3):
    print("This script requires Python 3.4 or higher")
    sys.exit(-1)

dopip = False
try:
    from elasticsearch import Elasticsearch
    from elasticsearch import VERSION as ES_VERSION
    ES_MAJOR = ES_VERSION[0]
except:
    dopip = True
    
if dopip and (getpass.getuser() != "root"):
    print("It looks like you need to install some python modules first")
    print("Either run this as root to do so, or run: ")
    print("pip3 install elasticsearch formatflowed netaddr certifi")
    sys.exit(-1)

elif dopip:
    print("Before we get started, we need to install some modules")
    print("Hang on!")
    try:
        subprocess.check_call(('pip3','install','elasticsearch','formatflowed', 'netaddr', 'certifi'))
        from elasticsearch import Elasticsearch
    except:
        print("Oh dear, looks like this failed :(")
        print("Please install elasticsearch and formatflowed before you try again:")
        print("pip install elasticsearch formatflowed netaddr certifi")
        sys.exit(-1)


# CLI arg parsing
parser = argparse.ArgumentParser(description='Command line options.')

parser.add_argument('--defaults', dest='defaults', action='store_true', 
                   help='Use default settings')

parser.add_argument('--clobber', dest='clobber', action='store_true',
                   help='Allow overwrite of ponymail.cfg & ../site/api/lib/config.lua (default: create *.tmp if either exists)')
parser.add_argument('--dbhost', dest='dbhost', type=str, nargs=1,
                   help='ES backend hostname')
parser.add_argument('--dbport', dest='dbport', type=str, nargs=1,
                   help='DB port')
parser.add_argument('--dbname', dest='dbname', type=str, nargs=1,
                   help='ES DB name')
parser.add_argument('--dbshards', dest='dbshards', type=int, nargs=1,
                   help='DB Shard Count')
parser.add_argument('--dbreplicas', dest='dbreplicas', type=int, nargs=1,
                  help='DB Replica Count')
parser.add_argument('--mailserver', dest='mailserver', type=str, nargs=1,
                   help='Host name of outgoing mail server')
parser.add_argument('--mldom', dest='mldom', type=str, nargs=1,
                   help='Domains to accept mail for via UI')
parser.add_argument('--wordcloud', dest='wc', action='store_true', 
                   help='Enable word cloud')
parser.add_argument('--skiponexist', dest='soe', action='store_true', 
                   help='Skip setup if ES index exists')
parser.add_argument('--noindex', dest='noi', action='store_true', 
                   help="Don't make an ES index, assume it exists")
parser.add_argument('--nocloud', dest='nwc', action='store_true', 
                   help='Do not enable word cloud')
parser.add_argument('--generator', dest='generator', type=str, nargs=1,
                   help='Document ID Generator to use (legacy, medium, redundant, full)')
args = parser.parse_args()    

print("Welcome to the Pony Mail setup script!")
print("Let's start by determining some settings...")
print("")


hostname = ""
port = 0
dbname = ""
mlserver = ""
mldom = ""
wc = ""
genname = ""
wce = False
shards = 0
replicas = -1


# If called with --defaults (like from Docker), use default values
if args.defaults:
    hostname = "localhost"
    port = 9200
    dbname = "ponymail"
    mlserver = "localhost"
    mldom = "example.org"
    wc = "Y"
    wce = True
    shards = 1
    replicas = 0
    genname = "redundant"

# Accept CLI args, copy them
if args.dbhost:
    hostname = args.dbhost[0]
if args.dbport:
    port = int(args.dbport[0])
if args.dbname:
    dbname = args.dbname[0]
if args.mailserver:
    mlserver = args.mailserver[0]
if args.mldom:
    mldom = args.mldom[0]
if args.wc:
    wc = args.wc
if args.nwc:
    wc = False
if args.dbshards:
    shards = args.dbshards[0]
if args.dbreplicas:
    replicas = args.dbreplicas[0]
if args.generator:
    genname = args.generator[0]
    
while hostname == "":
    hostname = input("What is the hostname of the ElasticSearch server? (e.g. localhost): ")
    
while port < 1:
    try:
        port = int(input("What port is ElasticSearch listening on? (normally 9200): "))
    except ValueError:
        pass

while dbname == "":
    dbname = input("What would you like to call the mail index (e.g. ponymail): ")

while mlserver == "":
    mlserver = input("What is the hostname of the outgoing mailserver? (e.g. mail.foo.org): ")
    
while mldom == "":
    mldom = input("Which domains would you accept mail to from web-replies? (e.g. foo.org or *): ")

while wc == "":
    wc = input("Would you like to enable the word cloud feature? (Y/N): ")
    if wc.lower() == "y":
        wce = True

while genname == "":
    gens = ['legacy', 'medium', 'redundant', 'full']
    print ("Please select a document ID generator:")
    print("1  LEGACY: The original document generator for v/0.1-0.8 (no longer recommended)")
    print("2  MEDIUM: The medium comprehensive generator for v/0.9 (no longer recommended)")
    print("3  REDUNDANT: Near-full message digest, discard MTA trail (recommended for clustered setups)")
    print("4  FULL: Full message digest with MTA trail (recommended for single-node setups).")
    try:
        gno = int(input("Please select a generator [1-4]: "))
        if gno <= len(gens) and gens[gno-1]:
            genname = gens[gno-1]
    except ValueError:
        pass
    
while shards < 1:
    try:
        shards = int(input("How many shards for the ElasticSearch index? "))
    except ValueError:
        pass

while replicas < 0:
    try:
        replicas = int(input("How many replicas for each shard? "))
    except ValueError:
        pass

print("Okay, I got all I need, setting up Pony Mail...")

def createIndex():
    es = Elasticsearch([
        {
            'host': hostname,
            'port': port,
            'use_ssl': False,
            'url_prefix': ''
        }],
        max_retries=5,
        retry_on_timeout=True
        )

    # Check if index already exists
    if es.indices.exists(dbname):
        if args.soe:
            print("ElasticSearch index '%s' already exists and SOE set, exiting quietly" % dbname)
            sys.exit(0)
        else:
            print("Error: ElasticSearch index '%s' already exists!" % dbname)
            sys.exit(-1)

    print("Creating index " + dbname)

    settings = {
        "number_of_shards" :   shards,
        "number_of_replicas" : replicas
    }

    mappings = {
        "mbox" : {
          "properties" : {
            "@import_timestamp" : {
              "type" : "date",
              "format" : "yyyy/MM/dd HH:mm:ss||yyyy/MM/dd"
            },
            "attachments" : {
              "properties" : {
                "content_type" : {
                  "type" : "string",
                  "index" : "not_analyzed"
                },
                "filename" : {
                  "type" : "string",
                  "index" : "not_analyzed"
                },
                "hash" : {
                  "type" : "string",
                  "index" : "not_analyzed"
                },
                "size" : {
                  "type" : "long"
                }
              }
            },
            "body" : {
              "type" : "string"
            },
            "cc": {
              "type": "string"
            },
            "date" : {
              "type" : "date",
              "store" : True,
              "format" : "yyyy/MM/dd HH:mm:ss",
              "index" : "not_analyzed"
            },
            "epoch" : { # number of seconds since the epoch
              "type" : "long",
              "index" : "not_analyzed"
            },
            "from" : {
              "type" : "string"
            },
            "from_raw" : {
              "type" : "string",
              "index" : "not_analyzed"
            },
            "in-reply-to" : {
              "type" : "string"
            },
            "list" : {
              "type" : "string"
            },
            "list_raw" : {
              "type" : "string",
              "index" : "not_analyzed"
            },
            "message-id" : {
              "type" : "string",
              "index" : "not_analyzed"
            },
            "mid" : {
              "type" : "string"
            },
            "private" : {
              "type" : "boolean"
            },
            "references" : {
              "type" : "string"
            },
            "subject" : {
              "type" : "string"
            },
            "to" : {
              "type" : "string"
            }
          }
        },
        "attachment" : {
          "properties" : {
            "source" : {
              "type" : "binary"
            }
          }
        },
        "mbox_source" : {
          "_all": {
            "enabled": False # this doc type is not searchable
          },
          "properties" : {
            "source" : {
              "type" : "binary"
            },
            "message-id" : {
              "type" : "string",
              "index" : "not_analyzed"
            },
            "mid" : {
              "type" : "string"
            }
          }
        },
        "mailinglists" : {
          "_all": {
            "enabled": False # this doc type is not searchable
          },
          "properties" : {
            "description" : {
              "type" : "string",
              "index" : "not_analyzed"
            },
            "list" : {
              "type" : "string",
#               "index" : "not_analyzed"
            },
            "name" : {
              "type" : "string",
              "index" : "not_analyzed"
            }
          }
        },
        "account" : {
          "_all": {
            "enabled": False # this doc type is not searchable
          },
          "properties" : {
            "cid" : {
              "type" : "string",
              "index" : "not_analyzed"
            },
            "credentials" : {
              "properties" : {
                "altemail" : {
                  "type" : "object"
                },
                "email" : {
                  "type" : "string",
                  "index" : "not_analyzed"
                },
                "fullname" : {
                  "type" : "string",
                  "index" : "not_analyzed"
                },
                "uid" : {
                  "type" : "string",
                  "index" : "not_analyzed"
                }
              }
            },
            "internal" : {
              "properties" : {
                "cookie" : {
                  "type" : "string",
                  "index" : "not_analyzed"
                },
                "ip" : {
                  "type" : "string",
                  "index" : "not_analyzed"
                },
                "oauth_used" : {
                  "type" : "string",
                  "index" : "not_analyzed"
                }
              }
            },
            "request_id" : {
              "type" : "string",
              "index" : "not_analyzed"
            }
          }
        },
        "notifications" : {
          "_all": {
            "enabled": False # this doc type is not searchable
          },
          "properties" : {
            "date" : {
              "type" : "date",
              "store" : True,
              "format" : "yyyy/MM/dd HH:mm:ss"
            },
            "epoch" : {
              "type" : "long"
            },
            "from" : {
              "type" : "string",
#               "index" : "not_analyzed"
            },
            "in-reply-to" : {
              "type" : "string",
#               "index" : "not_analyzed"
            },
            "list" : {
              "type" : "string",
#               "index" : "not_analyzed"
            },
            "message-id" : {
              "type" : "string",
              "index" : "not_analyzed"
            },
            "mid" : {
              "type" : "string",
#               "index" : "not_analyzed"
            },
            "private" : {
              "type" : "boolean"
            },
            "recipient" : {
              "type" : "string",
              "index" : "not_analyzed"
            },
            "seen" : {
              "type" : "long"
            },
            "subject" : {
              "type" : "string",
#               "index" : "not_analyzed"
            },
            "to" : {
              "type" : "string",
#               "index" : "not_analyzed"
            },
            "type" : {
              "type" : "string",
              "index" : "not_analyzed"
            }
          }
        },
        "mailinglists" : {
          "properties" : {
            "list" : {
              "type" : "string"
            },
            "name" : {
              "type" : "string"
            },
            "description" : {
              "type" : "string"
            }
          }
        }
    }
 
    res = es.indices.create(index = dbname, body = {
                "mappings" : mappings,
                "settings": settings
            }
        )
    
    print("Index created! %s " % res)
    
if not args.noi:
    try:
        import logging
        # elasticsearch logs lots of warnings on retries/connection failure
        logging.getLogger("elasticsearch").setLevel(logging.ERROR)
        createIndex()
    except Exception as e:
        print("Index creation failed: %s" % e)
        sys.exit(1)

ponymail_cfg = 'ponymail.cfg'
if not args.clobber and os.path.exists(ponymail_cfg):
    print("%s exists and clobber is not set" % ponymail_cfg)
    ponymail_cfg = 'ponymail.cfg.tmp'

print("Writing importer config (%s)" % ponymail_cfg)

with open(ponymail_cfg, "w") as f:
    f.write("""
###############################################################
# Pony Mail Configuration file                                             

# Main ES configuration
[elasticsearch]
hostname:               %s
dbname:                 %s
port:                   %u
ssl:                    false

#uri:                   url_prefix

#user:                  username
#password:              password

#%s

#backup:                database name

[archiver]
generator:              %s

[debug]
#cropout:               string to crop from list-id

###############################################################
            """ % (hostname, dbname, port, 
                   'wait:                  active shard count' if ES_MAJOR == 5 else 'write:                 consistency level (default quorum)', genname))
    f.close()

config_path = "../site/api/lib"
config_file = "config.lua"
if not args.clobber and os.path.exists(os.path.join(config_path,config_file)):
    print("%s exists and clobber is not set" % config_file)
    config_file = "config.lua.tmp"
print("mod_lua configuration (%s)" % config_file)
with open(os.path.join(config_path,config_file), "w") as f:
    f.write("""
local config = {
    es_url = "http://%s:%u/%s/",
    mailserver = "%s",
--  mailport = 1025, -- override the default port (25)
    accepted_domains = "%s",
    wordcloud = %s,
    email_footer = nil, -- see the docs for how to set this up.
    full_headers = false,
    maxResults = 5000, -- max emails to return in one go. Might need to be bumped for large lists
--  stats_maxBody = 200, -- max size of body snippet returned by stats.lua
--  stats_wordExclude = ".|..|...", -- patterns to exclude from word cloud generated by stats.lua
    admin_oauth = {}, -- list of domains that may do administrative oauth (private list access)
                     -- add 'www.googleapis.com' to the list for google oauth to decide, for instance.
    oauth_fields = { -- used for specifying individual oauth handling parameters.
-- for example:
--        internal = {
--            email = 'CAS-EMAIL',
--            name = 'CAS-NAME',
--            uid = 'REMOTE-USER',
--            env = 'subprocess' -- use environment vars instead of request headers
--        }
    },
--  allow_insecure_cookie = true, -- override the default (false) - only use for test installations 
--  no_association = {}, -- domains that are not allowed for email association
--  listsDisplay = 'regex', -- if defined, hide list names that don't match the regex
--  debug = false, -- whether to return debug information
    antispam = true  -- Whether or not to add anti-spam measures aimed at anonymous users.
}
return config
            """ % (hostname, port, dbname, mlserver, mldom, "true" if wce else "false"))
    f.close()
    
print("Copying sample JS config to config.js (if needed)...")
if not os.path.exists("../site/js/config.js") and os.path.exists("../site/js/config.js.sample"):
    shutil.copy("../site/js/config.js.sample", "../site/js/config.js")
    
    
print("All done, Pony Mail should...work now :)")
print("If you are using an external mail inbound server, \nmake sure to copy archiver.py and ponymail.cfg to it")
