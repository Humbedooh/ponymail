--[[
 Licensed to the Apache Software Foundation (ASF) under one or more
 contributor license agreements.  See the NOTICE file distributed with
 this work for additional information regarding copyright ownership.
 The ASF licenses this file to You under the Apache License, Version 2.0
 (the "License"); you may not use this file except in compliance with
 the License.  You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
]]--

-- This is stats.lua - the main stats/ML rendering script for the web.

local JSON = require 'cjson'
local elastic = require 'lib/elastic'
local user = require 'lib/user'
local aaa = require 'lib/aaa'
local config = require 'lib/config'
local cross = require 'lib/cross'
local utils = require 'lib/utils'

-- accumulate the monthly stats
local function monthly_emails(buckets, target)
    for _,v in pairs(buckets) do
        if v.doc_count > 0 then
            if target[v.key_as_string] then
                target[v.key_as_string] = target[v.key_as_string] + v.doc_count
            else
                target[v.key_as_string] = v.doc_count
            end
        end
    end
end

local BODY_MAXLEN = config.stats_maxBody or 200
-- words to exclude from word cloud:
local EXCLUDE = config.stats_wordExclude or ".|..|..."

local function sortEmail(thread)
    if thread.children and type(thread.children) == "table" then
        table.sort (thread.children, function (k1, k2) return k1.epoch > k2.epoch end )
        for k, v in pairs(thread.children) do
            sortEmail(v)
        end
    end
end

-- findSubject: match an email with an earlier one with the same topic
-- used for orphaned emails
local function findSubject(gblob, blob, subject, epoch, maxAge)
    local subj = subject:gsub("^[A-Za-z]:%s+", "")
    for k, v in pairs(blob) do
        if v.subject and v.subject == subj and v.epoch < epoch and (not maxAge or (maxAge and v.epoch >= (epoch - (maxAge*86400)))) then
            local mid = v['message-id']
            if gblob[mid] then
                return gblob[mid]
            end
        end
    end
    return nil
end

-- extract canonical email name from from field
local function extractCanonName(from)
    local name = from:match("([^<]+)%s*<.->") or from:match("%S+@%S+") or from:match("%((.-)%)") or "unknown"
    return name:gsub("\"", ""):gsub("%s+$", "")
end

function handle(r)
    cross.contentType(r, "application/json; charset=UTF-8")
    local DEBUG = config.debug or false
    local t = {}
    local START = DEBUG and r:clock() or nil
    local tnow = START
    local get = r:parseargs()
    -- statsOnly: Whether to only send statistical info (for n-grams etc), and not the
    -- thread struct and message bodies
    -- Param: quick
    local statsOnly = get.quick
    -- Param: list=<listname> or '*' (required)
    -- Param: domain=<domain> or '*' (required)
    if not get.list or not get.domain then
        r:puts("{}")
        return cross.OK
    end
    -- emailsOnly: return email summaries only, not derived data:
    -- i.e. omit thread_struct, top 10 participants and word-cloud
    local emailsOnly = get.emailsOnly
    local qs = "*" -- positive query
    local nqs = "" -- negative query
    local dd = "lte=1M"
    local maxresults = config.maxResults or 5000
    -- Param: page=n (page number, starts at 1)
    -- Param: per_page=n (results per page, max 5000)
    local page = math.max(tonumber(get.page) or 1, 1)
    local per_page = math.min(tonumber(get.per_page) or 100, maxresults)
    local offset = (page - 1) * per_page
    local account = user.get(r)
    -- Param: d=nnnnn (numeric)
    -- does not appear to be supported below
    if get.d and tonumber(get.d) and tonumber(get.d) > 0 then
        dd = tonumber(get.d)
    end
    -- Param: q=query
    if get.q and #get.q > 0 then
        local x = {}
        local nx = {}
        local q = get.q:gsub("+", " ") -- apache quirk?
        for k, v in pairs({'from','subject','body'}) do
            local y = {}
            local z = {}
            local words = {}

            -- first, grab all "foo bar" quotes
            for lword in q:gmatch([[("[^"]+")]]) do
                table.insert(words, lword)
            end
            -- then cut them out of the query
            for _, word in pairs(words) do
                q = q:gsub('"' .. word:gsub('[.%-%%%?%+]', "%%%1") .. '"', "")
            end

            -- then remaining single words
            for word in q:gmatch("(%S+)") do
                table.insert(words, word)
            end

            for _, word in pairs(words) do
                local preface = ""
                if word:match("^%-") then
                    preface = "-"
                    word = word:sub(2)
                end
                if preface == "" then
                    table.insert(y, ("%s:\"%s\""):format(v, r:escape_html( word:gsub("[()\"]+", "") )))
                else
                    table.insert(z, ("%s:\"%s\""):format(v, r:escape_html( word:gsub("[()\"]+", "") )))
                end
            end
            if #y > 0 then
                table.insert(x, "(" .. table.concat(y, " AND ") .. ")")
            end
            if #z > 0 then
                table.insert(nx, "(" .. table.concat(z, " OR ") .. ")")
            end
        end
        qs = table.concat(x, " OR ")
        if qs == "" then
            qs = "*"
        end
        nqs = table.concat(nx, " OR ")
    end

    local listraw = "<" .. get.list .. "." .. get.domain .. ">"
    local listdata = {
        name = get.list,
        domain = get.domain
    }

    local z = {}
    -- Param: header_from=
    -- Param: header_subject=
    -- Param: header_body=
    -- Param: header_to=
    for k, v in pairs({'from','subject','body', 'to'}) do
        if get['header_' .. v] then
            local word = get['header_' .. v]
            table.insert(z, ("(%s:\"%s\")"):format(v, r:escape_html( word:gsub("[()\"]+", "") )))
        end
    end
    if #z > 0 then
        if #qs > 0 and qs ~= "*" then
            qs = qs .. " AND (" .. table.concat(z, " AND ") .. ")"
        else
            qs = table.concat(z, " AND ")
        end
    end

    -- Debug time point 1
    if DEBUG then
      table.insert(t, r:clock() - tnow)
      tnow = r:clock()
    end

    local daterange = {gt = "now-1M", lte = "now+1d" }
    -- Param: dfrom=.*ddd (days ago to start)
    -- Param: dto=dddd.* (total days to match)
    -- Must both be present
    if get.dfrom and get.dto then
        local ef = tonumber(get.dfrom:match("(%d+)$")) or 0
        local et = tonumber(get.dto:match("^(%d+)")) or 0
        if ef > 0 and et > 0 then
            if et > ef then
                et = ef
            end
            daterange = {
                gte = "now-" .. ef .. "d",
                lte = "now-" .. (ef-et) .. "d"
            }
        end
    end
    if not get.d then
        get.d = dd
    end

    -- d=YYYY-mm translates into s+e being equal to d
    -- Param: d=yyyy-mm
    if not (get.s and get.e) and get.d and get.d:match("^%d+%-%d+$") then
        get.s = get.d
        get.e = get.d
    end
    -- Param: d=.*lte=n[wMyd].* (less than or equal to n days/weeks/etc ago)
    -- from now-nP to now+1d (P=period)
    if get.d then
        local lte = get.d:match("lte=([0-9]+[wMyd])")
        if lte then
            daterange.lte = "now+1d"
            daterange.gte = "now-" .. lte
            daterange.gt = nil
        end
    end
    -- Param: d=.*gte=n[wMyd].* (greater than or equal to n days/weeks/etc ago)
    -- before now-nP (P=period)
    if get.d then
        local gte = get.d:match("gte=([0-9]+[wMyd])")
        if gte then
            daterange.gte = nil
            daterange.gt = nil
            daterange.lte = "now-" .. gte
        end
    end
    -- Param: d=.*dfr=yyyy-mm-dd.* (dates from)
    -- start date for search
    if get.d then
        local y,m,d = get.d:match("dfr=(%d+)%-(%d+)%-(%d+)")
        if y and m and d then
            daterange.gte = ("%04u/%02u/%02u 00:00:00"):format(y,m,d)
            daterange.gt = nil
        end
    end
    -- Param: d=.*dto=yyyy-mm-dd.* (dates up to)
    -- end date for search
    if get.d then
        local y,m,d = get.d:match("dto=(%d+)%-(%d+)%-(%d+)")
        if y and m and d then
            daterange.lte = ("%04u/%02u/%02u 23:59:59"):format(y,m,d)
            daterange.gt = nil
        end
    end
    -- Param: s=yyyy-m[m]
    -- Param: e=yyyy-m[m]
    if get.s and get.e then
        local em = tonumber(get.e:match("%-(%d%d?)$"))
        local ey = tonumber(get.e:match("^(%d%d%d%d)"))
        local ec = utils.lastDayOfMonth(ey, em)
        daterange = {
            gte = get.s:gsub("%-","/").."/01 00:00:00",
            lte = get.e:gsub("%-","/").."/" .. ec .. " 23:59:59",
        }
    end
    local wc = false -- wildcard?
    local sterm = { -- which lists to process
              term = {
                  list_raw = listraw
              }
          }
    if get.list == "*" then
        wc = true
        sterm = {
            regexp = {
                list_raw = "\\<[^.]+\\." .. get.domain .. "\\>"
            }
        }
    end
    if get.domain == "*" then
        wc = true
        sterm = {
            wildcard = {
                list = "*"
            }
        }
    end

--[[ ============ Completed all parameter parsing, now process the data ============ ]]

    -- Check for changes?
    -- Param: since=epoch (optional, defaults to now)
    if get.since then
        local epoch = tonumber(get.since) or os.time()
        local doc = elastic.raw {
            _source = {'message-id'},
            query = {
                bool = {
                    must = {
                        {
                            range = {
                                epoch = {
                                    gt = epoch
                                }
                            }
                        },
                        {
                            range = {
                                date = daterange
                            }
                        },
                        sterm,
                        {
                            query_string = {
                                default_field = "subject",
                                query = qs
                            }
                        }
                    },
                    must_not = {
                        {
                            query_string = {
                                default_field = "subject",
                                query = nqs
                            }
                        }
                    }
                }
            },
            size = 1
        }
        if #doc.hits.hits == 0 then
            r:puts(JSON.encode{
                changed = false,
                  took = DEBUG and (r:clock() - START) or nil
            })
            return cross.OK
        end
    end

    -- Debug time point 2
    if DEBUG then
      table.insert(t, r:clock() - tnow)
      tnow = r:clock()
    end

    local cloud = nil
    if config.wordcloud and not statsOnly and not emailsOnly then
        cloud = {}
        -- Word cloud!
        local doc = elastic.raw {
            size = 0, -- we don't need the hits themselves
            terminate_after = 100,
            aggs = {
                cloud = {
                    terms =  {
                        field =  "subject",
                        size = 10,
                        exclude = EXCLUDE
                    }
                }
            },
            query = {
                bool = {
                    must = {
                        {
                            range = {
                                date = daterange
                            }
                        },
                        {
                            query_string = {
                                default_field = "subject",
                                query = qs
                            }
                        },
                        sterm,
                        {
                            term = {
                                private = false
                            }
                        }
                    },
                    must_not = {
                        {
                            query_string = {
                                default_field = "subject",
                                query = nqs
                            }
                        }
                    }
                }
            }
        }
        for x,y in pairs (doc.aggregations.cloud.buckets) do
            cloud[y.key] = y.doc_count
        end
    end
    -- Debug time point 3
    if DEBUG then
      table.insert(t, r:clock() - tnow)
      tnow = r:clock()
    end

    -- Get years active
    local NOWISH = math.floor(os.time()/600)
    local DATESPAN_KEY = "dateSpan:" .. NOWISH .. ":" .. get.list .. "@" .. get.domain
    local datespan = JSON.decode(r:ivm_get(DATESPAN_KEY) or "{}")

    if not (datespan.pubfirst and datespan.publast) then
        local doc = elastic.raw {
            size = 0,
            query = {
                bool = {
                    must = {
                        {
                            range = {
                                epoch = {
                                    gt = 0
                                }
                            }
                        },
                        sterm
                    }
                }
            },
            aggs = {
                lists = {
                    terms = {
                        field = "list_raw",
                        size = utils.MAX_LIST_COUNT
                    },
                    aggs = {
                        private = {
                            terms = {
                                field = "private",
                                size = 2
                            },
                            aggs = {
                                first = {
                                    min =  {
                                        field = "epoch"
                                    }
                                },
                                last = {
                                    max = {
                                        field = "epoch"
                                    }
                                },
                                monthly_emails = {
                                    date_histogram = {
                                        field = "date",
                                        interval = "month",
                                        format = "yyyy-MM"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        datespan = {}
        datespan.pubfirst = nil
        datespan.publast = nil
        datespan.monthly_emails = {}
        -- find public min and max (buckets will be empty if there are no matching lists)
        for _, list in pairs(doc.aggregations.lists.buckets) do
            for _, private in pairs(list.private.buckets) do
                if private.key_as_string == "false" then
                    monthly_emails(private.monthly_emails.buckets, datespan.monthly_emails)
                    if (datespan.publast == nil) or (private.last.value > datespan.publast) then datespan.publast = private.last.value end
                    if (datespan.pubfirst == nil) or (private.first.value < datespan.pubfirst) then datespan.pubfirst = private.first.value end
                end
            end
        end
        if datespan.publast == nil then -- did not find any values
            local NOW = os.time()
            datespan.publast = NOW
            datespan.pubfirst = NOW
        end

        -- find private min and max and store them if they could change the public ones
        -- store the list entries under the 'private' key to make them easier to process
        for _, list in pairs(doc.aggregations.lists.buckets) do
            for _, private in pairs(list.private.buckets) do
                if private.key_as_string == "true" then
                    datespan.private = datespan.private or {}
                    datespan.private[list.key] = datespan.private[list.key] or {}
                    datespan.private[list.key].monthly_emails = datespan.private[list.key].monthly_emails or {}
                    monthly_emails(private.monthly_emails.buckets, datespan.private[list.key].monthly_emails)
                    local prvlast = private.last.value
                    if prvlast > datespan.publast then
                        datespan.private[list.key].last = prvlast
                    end
                    local prvfirst = private.first.value
                    if prvfirst < datespan.pubfirst then
                        datespan.private[list.key].first = prvfirst
                    end
                end
            end
        end

        r:ivm_set(DATESPAN_KEY, JSON.encode(datespan))
    end

    -- process the raw list data:
    -- get the first and last dates, adjusting as necessary to allow for private lists
    local first = datespan.pubfirst
    local last = datespan.publast
    for lid, prvdates in pairs(datespan.private or {}) do
        if aaa.canAccessList(r, lid, account) then
            -- merge the stats from the private list
            for k,v in pairs(prvdates.monthly_emails) do
                if datespan.monthly_emails[k] then
                    datespan.monthly_emails[k] = datespan.monthly_emails[k] + v
                else
                    datespan.monthly_emails[k] = v
                end
            end
            if prvdates.first and prvdates.first < first then first = prvdates.first end
            if prvdates.last and prvdates.last > last then last = prvdates.last end
        end
    end

    -- extract years and months for response (using UTC, i.e. leading !)
    datespan.firstYear = tonumber(os.date("!%Y", first))
    datespan.firstMonth = tonumber(os.date("!%m", first))

    datespan.lastYear = tonumber(os.date("!%Y", last))
    datespan.lastMonth = tonumber(os.date("!%m", last))

    -- Debug time point 4
    if DEBUG then
      table.insert(t, r:clock() - tnow)
      tnow = r:clock()
    end

    -- Get threads
    local threads = {}
    local emails = {}
    local emls = {}
    local senders = {}

    local dhh = {}
    local total_hits = 0

    -- construct thread query
    local squery = {
        _source = {'message-id','in-reply-to','from','subject','epoch','references','list_raw', 'private', 'attachments', 'body'},
        query = {
            bool = {
                must = {
                    {
                        range = {
                            date = daterange
                        }
                    },
                    sterm,
                    {
                        query_string = {
                            default_field = "subject",
                            query = qs
                        }
                    }
                },
                must_not = {
                    {
                        query_string = {
                            default_field = "subject",
                            query = nqs
                        }
                    }
                }
            }
        },
        sort = {
            {
                epoch = {
                    order = "desc"
                }
            }
        },
        size = per_page
    }

    -- If max results limit is beyond the limit, we have to do a scroll
    if maxresults > elastic.MAX_RESULT_WINDOW then
        -- First get total count
        local count_query = {
            query = squery.query,
            size = 0
        }
        local count_result = elastic.raw(count_query)
        total_hits = count_result.hits.total

        -- Then do scroll logic...
        squery.size = per_page
        local js, sid = elastic.scroll(squery)

        local skip_batches = math.floor(offset / per_page)
        for i = 1, skip_batches do
            js, sid = elastic.scroll(sid)
            if not (js and js.hits and js.hits.hits and #js.hits.hits > 0) then
                break
            end
        end

        if js and js.hits and js.hits.hits and #js.hits.hits > 0 then
            for k, v in pairs(js.hits.hits) do
                table.insert(dhh, v)
            end
        end

        elastic.clear_scroll(sid)
    else
        -- Standard query
        squery.from = offset
        local doc = elastic.raw(squery)
        dhh = doc.hits.hits
        total_hits = doc.hits.total
    end

    -- Debug time point 5
    if DEBUG then
    table.insert(t, r:clock() - tnow)
    tnow = r:clock()
    end


    for k = #dhh, 1, -1 do
        local v = dhh[k]
        local email = v._source
        if aaa.canAccessDoc(r, email, account) then

            local eml = utils.extractCanonEmail(email.from)
            local gravatar = r:md5(eml:lower())
            email.gravatar = gravatar

            local name = extractCanonName(email.from)
            local eid = ("%s <%s>"):format(name, eml)
            if not statsOnly and not emailsOnly then
                senders[eid] = senders[eid] or {
                    email = eml,
                    gravatar = gravatar,
                    name = name,
                    count = 0
                }
                senders[eid].count = senders[eid].count + 1
            end
            local mid = email['message-id']
            local irt = email['in-reply-to']
            email.id = v._id
            email.irt = irt

            -- only calculate threads if necessary
            if not emailsOnly then
                emails[mid] = {
                    tid = v._id,
                    nest = 1,
                    epoch = email.epoch,
                    children = {

                    }
                }

                if not irt or irt == JSON.null or #irt == 0 then
                    irt = ""
                end
                if not emails[irt] and email.references and email.references ~= JSON.null then
                    for ref in email.references:gmatch("([^%s]+)") do
                        if emails[ref] then
                            irt = ref
                            break
                        end
                    end
                end

                if not irt or irt == JSON.null or #irt == 0 then
                    irt = email.subject:gsub("^[a-zA-Z]+:%s+", "")
                end

                -- If we can't match by in-reply-to or references, match/group by subject, ignoring Re:/Fwd:/etc
                if not emails[irt] then
                    irt = email.subject:gsub("^[a-zA-Z]+:%s+", "")
                    while irt:match("^[a-zA-Z]+:%s+") do
                        irt = irt:gsub("^[a-zA-Z]+:%s+", "")
                    end
                end
                local refpoint = irt or email['references'] or ""
                local point = emails[irt] or (#refpoint > 0 and findSubject(emails, emls, irt, email.epoch))
                -- Try a little harder??
                if not point and email.subject:match("^[A-Za-z]+:%s+") then  -- if this is a 'Re:' or 'Aw:' or 'Fwd:', try to find parent anyway
                    point = findSubject(emails, emls, irt, email.epoch, 30) -- at most, go back 30 days. if not, then they don't belong together...I guess
                end

                if point then
                    if point.nest < 50 then
                        point.nest = point.nest + 1
                        table.insert(point.children, emails[mid])
                    end
                else
                    if (irt ~= JSON.null and #irt > 0) then
                        emails[irt] = {
                            children = {
                                emails[mid]
                            },
                            nest = 1,
                            epoch = email.epoch,
                            tid = v._id
                        }
                        emails[mid].nest = emails[irt].nest + 1
                        table.insert(threads, emails[irt])
                    else
                        table.insert(threads, emails[mid])
                    end
                end
                -- needed for emailsOnly
                email.references = nil
            end

            email.to = nil
            -- Duplicate of email.irt
            email['in-reply-to'] = nil
            if not account and config.antispam then
                email.from = email.from:gsub("(%S+)@(%S+)", function(a,b) return a:sub(1,2) .. "..." .. "@" .. b end)
            end
            if email.attachments then
                email.attachments = #email.attachments
            else
                email.attachments = 0
            end
            email.body = #email.body < BODY_MAXLEN and email.body or email.body:sub(1, BODY_MAXLEN) .. "..."
            if not statsOnly then
                table.insert(emls, email)
            else
                table.insert(emls, {epoch= email.epoch})
            end
        end
    end

    local allparts = 0 -- number of participants
    local top10 = {}

    if not statsOnly and not emailsOnly then
        local stable = {}
        for k, v in pairs(senders) do
            table.insert(stable, v)
        end
        table.sort(stable, function(a,b) return a.count > b.count end )
        allparts = #stable
        for k, v in pairs(stable) do
            if k <= 10 then
                table.insert(top10, v)
            else
                break
            end
        end
    end

    -- anonymize emails if not logged in - anti-spam!
    if not account and config.antispam then
        for k, v in pairs(top10) do
            top10[k].email = top10[k].email:gsub("(%S+)@(%S+)", function(a,b) return a:sub(1,2) .. "..." .. "@" .. b end)
        end
    end

    -- Debug time point 6
    if DEBUG then
      table.insert(t, r:clock() - tnow)
      tnow = r:clock()
    end

    sortEmail(threads)

    -- Debug time point 7
    if DEBUG then
      table.insert(t, r:clock() - tnow)
      tnow = r:clock()
    end

    if JSON.encode_max_depth then
        -- TODO see #439
        JSON.encode_max_depth(1000)
    end
    listdata.max = maxresults
    listdata.using_wc = wc
    listdata.no_threads = #threads
    if not statsOnly and not emailsOnly then
        listdata.thread_struct = threads
    end
    listdata.firstYear = datespan.firstYear
    listdata.lastYear = datespan.lastYear
    listdata.firstMonth = datespan.firstMonth
    listdata.lastMonth = datespan.lastMonth
    listdata.monthly_emails = datespan.monthly_emails
    listdata.list = listraw:gsub("^([^.]+)%.", "%1@"):gsub("[<>]+", "")
    listdata.emails = emls
    listdata.hits = #emls
    listdata.searchlist = listraw
    listdata.participants = top10
    listdata.cloud = cloud
    if DEBUG then
      listdata.took = r:clock() - START
      listdata.debug = t
    end
    listdata.numparts = allparts
    listdata.unixtime = os.time()
    if get.showQuery and not config.noShowQuery then
        listdata.squery = squery
        listdata.sdata = get
    end

    -- Add pagination metadata
    listdata.pagination = {
        page = page,
        per_page = per_page,
        total = total_hits,
        total_pages = math.ceil(total_hits/per_page)
    }

    r:puts(JSON.encode(listdata))

    return cross.OK
end

cross.start(handle)
