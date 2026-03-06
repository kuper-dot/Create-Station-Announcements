print("this script will save operator IDs for metro and TFW.")
print("make sure this computer has access to a train station")
print("with a train on it. it must have a schedule with nothing")
print("but two travel sections: one with operator metro, one")
print("with TFW. if this is not the case, press any key.")
print("metro must come first, then TFW, then Rural.")

print("\nif everything is good, press enter.")

function main()
    local event, key = os.pullEvent("key")
    if key ~= keys.enter then return end

    local station = peripheral.find("Create_Station")
    local schedule = station.getSchedule().entries

    local metro_id = schedule[1].instruction.data.train_category
    shell.run("mkdir /opr")
    io.open("/opr/metro.id", "w"):write(
        textutils.serializeJSON(metro_id)
    ):close()

    local tfw_id = schedule[2].instruction.data.train_category
    io.open("/opr/tfw.id", "w"):write(
        textutils.serializeJSON(tfw_id)
    ):close()
    print("done. thank you for using the thing")
    
    local rural_id = schedule[3].instruction.data.train_category
    io.open("/opr/rural.id", "w"):write(
        textutils.serializeJSON(rural_id)
    ):close()
    
    
end

main()
