local player = require "player"
local TFWOperatorID, MetroOperatorID, RuralOperatorID
local trainCooldowns = {}
local COOLDOWN_TIME = 60 -- seconds

local peripherals = {}
local peripheralsState = {}

function getStationPeripherals()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "Create_Station" then
            table.insert(peripherals, { name = name, p = peripheral.wrap(name) })
        end
    end
    assert(#peripherals > 0, "[getStationPeripherals()]: no peripheral(s) found!")
end 

function stateFor(stnName)
    peripheralsState[stnName] = peripheralsState[stnName] or {
        trainCooldowns = {},
        lastTrainName = ""
    }
    
    return peripheralsState[stnName]
end 

local function stripPlatform(stationName)
    if not stationName then return nil end

    local cleaned = stationName:match("^(.*)%s") or stationName
    cleaned = string.lower(cleaned)
    cleaned = string.gsub(cleaned, "%s+", "")
    cleaned = cleaned .. ".wav"

    return cleaned
end

local function stripPlatformNoWav(stationName)
    if not stationName then return nil end

    local cleaned = stationName:match("^(.*)%s") or stationName
    cleaned = string.lower(cleaned)
    cleaned = string.gsub(cleaned, "%s+", "")

    return cleaned
end

function getOperatorIDs()
    print("reading TFW operator ID")
    local f = io.open("/opr/tfw.id", "r")
    TFWOperatorID = textutils.unserializeJSON(f:read())
    f:close()

    print("reading metro operator ID")
    local f = io.open("/opr/metro.id", "r")
    MetroOperatorID = textutils.unserializeJSON(f:read())
    f:close()
    
    print("reading rural operator ID")
    local f = io.open("/opr/rural.id", "r")
    RuralOperatorID = textutils.unserializeJSON(f:read())
    f:close()
    
end

function areTablesEqual(t1, t2)
    for index1, value1 in pairs(t1) do
        local value2 = t2[index1]
        if value1 ~= value2 then return false end
    end
    return true
end

function findLastScheduleSection(schedule)
    for i = (schedule.progress or 0) + 1, 1, -1 do

        if schedule.entries[i].instruction.id ==
            "createrailwaysnavigator:travel_section" then
            return schedule.entries[i], i
        end
    end
end

function getScheduleEntry(entry)
    local instr = entry.instruction
    if instr.id == "create:destination" then
        return stripPlatformNoWav(instr.data.text)
    elseif instr.id == "createrailwaysnavigator:prioritized_destination_instruction" then
        return stripPlatformNoWav(instr.data.filters and instr.data.filters[1])
    end
    return nil
end

function findDestination(schedule)
    local entries = schedule.entries
    local curIndex = (schedule.progress or 0) + 1 -- we want to start looking from the next instruction, since the current one does not need to be announced
    local lastIndex = #entries
    if curIndex >= #entries then curIndex = 2 end -- if we are at the end of the schedule, we want to loop back to the start, since it is cyclic

    print("looking for next section starting from index " .. curIndex .. " to " .. #entries)
    for i = curIndex, #entries do
        if entries[i].instruction.id == "createrailwaysnavigator:travel_section" then 
            lastIndex = i --Find the next section, and set the lastIndex to it, so we only look within the current section
            print("found next section at index " .. i)
            break
        end
    end
 -- we want to start looking backwards from the instruction before the next section, since the next section is not relevant for us
            while lastIndex > (schedule.progress-1 or -1) and -- we want to make sure the index represents destination instruction (-1 to allow current station to be included if it is the last stop)
                entries[lastIndex].instruction.id ~= "create:destination" and
                entries[lastIndex].instruction.id ~= "createrailwaysnavigator:prioritized_destination_instruction"
            do
                lastIndex = lastIndex - 1 -- It will keep going back until it finds a destination instruction, or it reaches the current station
            end
            print("Last stop is at index " .. lastIndex)
        
    return lastIndex
end
    

-- =====================================
-- STRIP PLATFORM
-- =====================================



function getStations(schedule, station)
    local entries = schedule.entries
    local t = {}
    local section, start = findLastScheduleSection(schedule)
    local index = findDestination(schedule)
    for i = start, index do
        if entries[i].instruction.id == "create:destination" then
            table.insert(t, entries[i].instruction.data.text)
        end
    end
    return t
end

function getCallingPoints(schedule, currentStation)
    local entries = schedule.entries
    local locations = {}

    -- 1. Find the destination and its index in the schedule
    local destIndex = findDestination(schedule)
    if not destIndex then
        print("Could not determine destination index.")
        return locations
    end

    -- 2. Find the start of the current section
    -- We look backwards from the destination index to find the nearest 'travel_section'
    local sectionStartIndex = 1
    for i = destIndex, 1, -1 do
        if entries[i].instruction.id == "createrailwaysnavigator:travel_section" then
            sectionStartIndex = i
            break
        end
    end

    local destinationName = getScheduleEntry(entries[destIndex])
    local started = false

    -- 3. Only iterate within the current section
    for i = sectionStartIndex, destIndex do
        local name = getScheduleEntry(entries[i])
        
        if name then
            if name == currentStation then
                -- We found where we are; start collecting from the NEXT entry
                started = true
            elseif started then
                table.insert(locations, name)
                
                -- Stop if we hit the destination name
                if name == destinationName then
                    break
                end
            end
        end
    end

    print("Returning " .. #locations .. " calling points for this section.")
    return locations
end
-- This needs to be rewriten to not use findLastScheduleSection. 
function getTrainOperatorID(schedule)
    -- find the last Schedule Section
    -- schedule[schedule.progress + 1]

    return findLastScheduleSection(schedule).instruction.data.train_category or TFWOperatorID
end

function getTrainOperator(schedule)
    local id = getTrainOperatorID(schedule)

    if areTablesEqual(id, MetroOperatorID) then return "Metro" end
    if areTablesEqual(id, RuralOperatorID) then return "rural" end
    -- return by default
    return "TFW"
end

function getCarriageCount(trainName) return
    tonumber(trainName:match(".+ (%d+)")) end

function getPlatform(stationName)
    local stationName = stationName:gsub("^%s+", ""):gsub("%s+$", "")

    local platformCode = stationName:match("%sP([%w%-]+)$")
    return platformCode
end

function announceCallingPoints(schedule, currentStation)
    -- lowercase and remove spaces from station name
    local callingPoints = getCallingPoints(schedule, currentStation)
    local toPlay = {}

    if #callingPoints == 0 then print("no calling points to announce, breaking..") return {} end

    if #callingPoints == 1 then
        print("detected only one calling point, throwing 'only'..")
        table.insert(toPlay, "/disk/sm/stations/" .. stripPlatform(callingPoints[1]))
        table.insert(toPlay, "disk/sm/misc/only.wav")
    else
        for i, point in ipairs(callingPoints) do
            if i == #callingPoints then
                print("last entry, inserting '/misc/and.wav' before...")
                table.insert(toPlay, "disk/sm/misc/and.wav")
            end
            
            table.insert(toPlay, "/disk/sm/stations/" .. stripPlatform(point))
        end
    end

    print("compiled table: ", toPlay)
    return toPlay
end



function processStation(st)
    local stnName = st.name
    local stn = st.p
    local station = stn
    local stnState = stateFor(stnName)
    if not stn.isTrainPresent() then
        stnState.lastTrainName = ""
        return
    end
    
        local hasTrain = station.isTrainPresent()

        if hasTrain then
            local trainName = station.getTrainName()
            local currentTime = os.clock()

            local lastPlayed = trainCooldowns[trainName]

            -- If train has never played OR cooldown expired
            if not lastPlayed or (currentTime - lastPlayed) >= COOLDOWN_TIME then
                trainCooldowns[trainName] = currentTime

                local schedule = station.getSchedule()

                print("Announcing train:", trainName)

                local cars = getCarriageCount(trainName)
                local operator
                local destination

                if schedule then
                    operator = getTrainOperator(schedule)

                    destination = findDestination(schedule)
                    destination = getScheduleEntry(schedule.entries[destination])
                end

                local platform = getPlatform(station.getStationName())

                local destName = "Unknown"
                print("The dest type is:" .. type(destination))
                print("The dest is:" .. destination)

                if type(destination) == "table" then
                    destName = getScheduleEntry(destination) or "Unknown"
                elseif type(destination) == "string" then
                    destName = destination
                end

                -- player.play({
                --     "disk/sm/misc/platform.wav", -- "Platform"
                --     string.format("disk/sm/numbers/%d.wav", platform), -- "X"
                --     "disk/sm/misc/forthe.wav", -- "for the"
                --     string.format("disk/sm/misc/%s.wav", operator), -- "<operator>"
                --     "disk/sm/misc/serviceto.wav", -- "service to"
                --     string.format("disk/sm/stations/%s", stripPlatform(destName)), -- "<destination>"
                --     "disk/sm/misc/callingat.wav", -- "calling at"
                --     table.unpack(announceCallingPoints(schedule, station.getStationName())) -- calling points
                -- })
                
                local cpAudio = announceCallingPoints(schedule, stripPlatformNoWav(station.getStationName()))
                
                local clips = {
                    "disk/sm/misc/jingle.wav",
                    "disk/sm/misc/platform.wav",
                }
                  
                local function buildPlatformAudio(platform, clips)
                if platform then
                    local platformStr = tostring(platform)
                    local numberPart = platformStr:match("(%d+)")
                    local letterPart = platformStr:match("([A-Za-z])")
                    
                    -- Number audio (e.g. 1 in 1A)
                        if numberPart then
                            table.insert(clips, string.format("disk/sm/numbers/%d.wav", numberPart))
                        end
                
                        -- Letter audio (e.g. A in 1A)
                        if letterPart then
                            table.insert(clips, string.format("disk/sm/numbers/%s.wav", letterPart:lower()))
                        end
                    end 
                end
                print(platform)
                buildPlatformAudio(platform, clips)
                table.insert(clips, "disk/sm/misc/forthe.wav")
                table.insert(clips, string.format("disk/sm/misc/%s.wav", operator))
                table.insert(clips, "disk/sm/misc/serviceto.wav")
                table.insert(clips, string.format("disk/sm/stations/%s", stripPlatform(destName)))
                
                -- Only add "calling at ..." if we actually have calling points
                if cpAudio and #cpAudio > 0 then
                    table.insert(clips, "disk/sm/misc/callingat.wav")
                    for _, clip in ipairs(cpAudio) do
                        table.insert(clips, clip)
                    end
                end
                
                player.play(clips)
                sleep(0.1)
                player.play({
                    "disk/sm/misc/thistrainisformedof.wav",
                    string.format("disk/sm/numbers/%d.wav", cars),
                    "disk/sm/misc/coaches.wav"
                })
                
                local debugFile = io.open("/schedule_dump.json", "w")

                debugFile:write(textutils.serializeJSON({
                    progress = schedule.progress,
                    cyclic = schedule.cyclic,
                    entries = schedule.entries
                }, true))

                debugFile:close()
                print(string.format(
                          "cars %d operator %s platform %s destination %s",
                          cars, operator, platform, destName))
            end
        end
end


local station, speaker

function main()
    
    stations = getStationPeripherals()
    local lastTrainName = ""
    function getPeripherals()
        
        station = peripheral.find("Create_Station")
        speaker = peripheral.find("speaker")
    end

    if not pcall(getOperatorIDs) then
        print(
            "failed to read operator IDs. you probably need to run 'probe_ids' (without quotes) first.")
    end

    if not pcall(getPeripherals) then
        print(
            "failed to fetch peripherals. make sure the computer is wired to a station and speaker")
    end

    print("entering main loop.")
    while true do
        --print(peripherals)
        for _, st in ipairs(peripherals) do
            local ok, err = pcall(processStation, st)
            if not ok then print(("Station %s error: %s"):format(st.name, tostring(err))) end
            
    end
    sleep(0.2)
    end
end

main()