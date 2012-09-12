class DwarfAI
    class Plan
        attr_accessor :ai
        attr_accessor :tasks
        def initialize(ai)
            @ai = ai
            @nrdig = 0
            @tasks = []
            @tasks << [:checkrooms]
            df.cuttrees(:any, 6, true)
            add_manager_order(:ConstructTable, 2)
            add_manager_order(:ConstructThrone, 2)
            add_manager_order(:ConstructBed, 2)
            add_manager_order(:ConstructDoor, 2)
            add_manager_order(:ConstructCabinet, 2)
        end

        def debug(str)
            puts "AI: #{df.cur_year}:#{df.cur_year_tick} #{str}" if $DEBUG
        end

        def update
            @cache_nofurnish = {}
            @nrdig = @tasks.count { |t| t[0] == :digroom and t[1].type != :corridor }
            @tasks.delete_if { |t|
                case t[0]
                when :wantdig
                    @nrdig += 1 if t[1].w*t[1].h >= 10
                    digroom(t[1]) if @nrdig < 2
                when :digroom
                    if t[1].dug?
                        t[1].status = :dug
                        construct_room(t[1])
                        true
                    end
                when :construct_workshop
                    try_construct_workshop(t[1])
                when :setup_farmplot
                    try_setup_farmplot(t[1])
                when :furnish
                    try_furnish(t[1], t[2])
                when :makeroom
                    try_makeroom(t[1])
                when :checkconstruct
                    try_endconstruct(t[1])
                when :dig_cistern
                    try_digcistern(t[1])
                when :checkidle
                    checkidle
                when :checkwagons
                    checkwagons
                when :checkrooms
                    checkrooms
                end
            }
        end

        def digging?
            @tasks.find { |t| t[0] == :wantdig or t[0] == :digroom }
        end

        def idle?
            @tasks.empty?
        end

        def new_citizen(uid)
            @tasks << [:checkidle] unless @tasks.find { |t| t[0] == :checkidle }
            getbedroom(uid)
            getdiningroom(uid)
        end

        def del_citizen(uid)
            freebedroom(uid)
            freediningroom(uid)
            # TODO coffin/memorialslab for dead citizen
        end
        
        def checkwagons
            ret = true
            df.world.buildings.other[:WAGON].each { |w|
                if w.kind_of?(DFHack::BuildingWagonst) and not w.contained_items.find { |i| i.use_mode == 0 }
                    df.building_deconstruct(w)
                else
                    ret = false
                end
            }
            ret
        end

        def checkidle
            # if nothing better to do, order the miners to dig remaining stockpiles, workshops, and a few bedrooms
            if not digging?
                freebed = 3
                if r = @rooms.find { |_r| _r.type == :workshop and _r.subtype and _r.status == :plan } ||
                       @rooms.find { |_r| _r.type == :bedroom and not _r.owner and ((freebed -= 1) >= 0) and _r.status == :plan } ||
                       @rooms.find { |_r| _r.type == :stockpile and not _r.misc[:secondary] and _r.subtype and _r.status == :plan } ||
                       @rooms.find { |_r| _r.type == :stockpile and _r.subtype and _r.status == :plan }
                    wantdig(r)
                    false
                else
                    true
                end
            end
        end

        def checkrooms
            @checkroom_idx ||= 0
            # approx 300 rooms + update is called every 4s at 30fps -> should check everything every 5mn
            ncheck = 4

            @rooms[@checkroom_idx % @rooms.length, ncheck].each { |r|
                checkroom(r)
            }

            @corridors[@checkroom_idx % @corridors.length, ncheck].each { |r|
                checkroom(r)
            }

            @checkroom_idx += ncheck
            @checkroom_idx = 0 if @checkroom_idx >= @rooms.length and @checkroom_idx >= @corridors.length
            false
        end

        # ensure room was not tantrumed etc
        def checkroom(r)
            case r.status
            when :plan
                # moot
            when :dig
                # designation cancelled: damp stone etc
                r.dig
            when :dug, :finished
                # cavein / tree
                r.dig
                # tantrumed furniture
                r.layout.each { |f|
                    next if f[:ignore]
                    if f[:bld_id] and not df.building_find(f[:bld_id])
                        df.add_announcement("AI: fix furniture #{f[:item]} for #{r.type} #{r.subtype}", 7, false) { |ann| ann.pos = [r.x+f[:x].to_i, r.y+f[:y].to_i, r.z+f[:z].to_i] }
                        f.delete :bld_id
                        f.delete :queue_build
                        @tasks << [:furnish, r, f]
                    end
                }
                # tantrumed building
                if r.misc[:bld_id] and not r.dfbuilding
                    r.misc.delete :bld_id
                    construct_room(r)
                end
            end
        end

        def getbedroom(id)
            if r = @rooms.find { |_r| _r.type == :bedroom and (not _r.owner or _r.owner == id) } ||
                   @rooms.find { |_r| _r.type == :bedroom and _r.status == :plan and not _r.misc[:queue_dig] }
                wantdig(r)
                set_owner(r, id)
                df.add_announcement("AI: assigned a bedroom to #{df.unit_find(id).name.to_s(false)}", 7, false) { |ann| ann.pos = [r.x+1, r.y+1, r.z] }
            else
                puts "AI cant getbedroom(#{id})"
            end
        end

        def getdiningroom(id)
            dwarves_per_farmtile = 2    # XXX tweak
            if r = @rooms.find { |_r| _r.type == :farmplot and _r.subtype == :food and _r.misc[:users].length < _r.w*_r.h*dwarves_per_farmtile }
                wantdig(r)
                r.misc[:users] << id
            end

            dwarves_per_table = 3
            if r = @rooms.find { |_r| _r.type == :dininghall and _r.layout.find { |f| f[:users] and f[:users].length < dwarves_per_table } }
                wantdig(r)
                table = r.layout.find { |f| f[:item] == :table and f[:users].length < dwarves_per_table }
                chair = r.layout.find { |f| f[:item] == :chair and f[:users].length < dwarves_per_table }
                table.delete :ignore
                chair.delete :ignore
                table[:users] << id
                chair[:users] << id
                if r.status == :finished
                    furnish_room(r)
                end
            end
        end

        def freebedroom(id)
            if r = @rooms.find { |_r| _r.type == :bedroom and _r.owner == id }
                set_owner(r, nil)
            end
        end

        def freediningroom(id)
            @rooms.each { |r|
                if r.type == :dininghall
                    r.layout.each { |f| f[:users].delete(id) if f[:users] }
                elsif r.type == :farmplot
                    r.misc[:users].delete id
                end
            }
        end

        def set_owner(r, uid)
            r.owner = uid
            if r.misc[:bld_id]
                u = df.unit_find(uid) if uid
                df.building_setowner(df.building_find(r.misc[:bld_id]), u)
            end
        end

        # queue a room for digging when other dig jobs are finished
        # with faster=true, this job is inserted in front of existing similar room jobs
        def wantdig(r, faster=false)
            return true if r.misc[:queue_dig] or r.status != :plan
            debug "wantdig #{@rooms.index(r)} #{r.type} #{r.subtype}"
            r.misc[:queue_dig] = true
            if faster and idx = @tasks.index { |t| t[0] == :wantdig and t[1].type == r.type }
                @tasks.insert(idx, [:wantdig, r])
            else
                @tasks << [:wantdig, r]
            end
        end

        def digroom(r)
            return true if r.status != :plan
            debug "digroom #{@rooms.index(r)} #{r.type} #{r.subtype}"
            r.misc.delete :queue_dig
            r.status = :dig
            r.dig
            @tasks << [:digroom, r]
            r.accesspath.each { |ap| digroom(ap) }
            r.layout.each { |f|
                build_furniture(f) if f[:makeroom]
            }
            if r.type == :workshop
                case r.subtype
                when :Dyers
                    ensure_workshop(:Carpenters)
                    add_manager_order(:MakeBarrel)
                    add_manager_order(:MakeBucket)
                when :Ashery
                    ensure_workshop(:Masons)
                    ensure_workshop(:Carpenters)
                    add_manager_order(:ConstructBlocks)
                    add_manager_order(:MakeBarrel)
                    add_manager_order(:MakeBucket)
                end

                # add minimal stockpile in front of workshop
                if sptype = {:Masons => :stone, :Carpenters => :wood, :Craftsdwarfs => :refuse,
                        :Farmers => :food, :Fishery => :food, :Jewelers => :gems, :Loom => :cloth,
                        :Clothiers => :cloth, :Still => :food
                }[r.subtype]
                    # XXX hardcoded fort layout
                    y = (r.layout[0][:y] > 0 ? r.y2+2 : r.y1-2)  # check door position
                    sp = Room.new(:stockpile, sptype, r.x1, r.x2, y, y, r.z1)
                    sp.misc[:workshop] = r
                    @rooms << sp
                    digroom(sp)
                end
            elsif r.type == :well and r.subtype == :well
                ensure_workshop(:Masons)
                ensure_workshop(:Mechanics)
                ensure_workshop(:Carpenters)
                add_manager_order(:ConstructBlocks)
                add_manager_order(:ConstructMechanisms)
                add_manager_order(:MakeBucket)
                #add_manager_order(:MakeChain)
            end
            @nrdig += 1
            true
        end

        def construct_room(r)
            debug "construct #{@rooms.index(r)} #{r.type} #{r.subtype}"
            case r.type
            when :corridor
                furnish_room(r)
            when :stockpile
                construct_stockpile(r)
            when :workshop
                @tasks << [:construct_workshop, r]
            when :farmplot
                construct_farmplot(r)
            when :well
                if r.subtype == :well
                    furnish_room(r)
                else
                    @tasks << [:dig_cistern, r]
                end
            else
                r.layout.each { |f|
                    @tasks << [:furnish, r, f] if f[:makeroom]
                }
            end
        end

        def furnish_room(r)
            r.layout.each { |f| @tasks << [:furnish, r, f] }
            r.status = :finished
        end

        FurnitureOtheridx = {}  # :moo => :MOO
        FurnitureRtti = {}      # :moo => :item_moost
        FurnitureBuilding = {}  # :moo => :Moo
        FurnitureWorkshop = {   # :moo => :Masons
            :bed => :Carpenters,
        }
        FurnitureOrder = {      # :moo => :ConstructMoo
            :chair => :ConstructThrone,
        }

        def try_furnish(r, f)
            return true if f[:bld_id]
            return true if f[:ignore]
            return true if f[:item] == :pillar
            return try_furnish_well(r, f) if f[:item] == :well
            build_furniture(f)
            return if @cache_nofurnish[f[:item]]
            oidx = FurnitureOtheridx[f[:item]] ||= "#{f[:item]}".upcase.to_sym
            rtti = FurnitureRtti[f[:item]] ||= "item_#{f[:item]}st".to_sym
            if itm = df.world.items.other[oidx].find { |i| i._rtti_classname == rtti and df.building_isitemfree(i) rescue next }
                debug "furnish #{@rooms.index(r)} #{r.type} #{r.subtype} #{f[:item]}"
                bldn = FurnitureBuilding[f[:item]] ||= "#{f[:item]}".capitalize.to_sym
                bld = df.building_alloc(bldn)
                df.building_position(bld, [r.x+f[:x].to_i, r.y+f[:y].to_i, r.z])
                df.building_construct(bld, [itm])
                if f[:makeroom]
                    r.misc[:bld_id] = bld.id
                    @tasks << [:makeroom, r]
                end
                f[:bld_id] = bld.id
                true
            else
                @cache_nofurnish[f[:item]] = true
                false
            end
        end

        def try_furnish_well(r, f)
            # XXX build furniture?
            if block = df.world.items.other[:BLOCKS].find { |i|
                i.kind_of?(DFHack::ItemBlocksst) and df.building_isitemfree(i)
            } and mecha = df.world.items.other[:TRAPPARTS].find { |i|
                i.kind_of?(DFHack::ItemTrappartsst) and df.building_isitemfree(i)
            } and bucket = df.world.items.other[:BUCKET].find { |i|
                i.kind_of?(DFHack::ItemBucketst) and df.building_isitemfree(i) and not i.itemrefs.find { |ir| ir.kind_of?(DFHack::GeneralRefContainsItemst) }
            } and chain = df.world.items.other[:CHAIN].find { |i|
                i.kind_of?(DFHack::ItemChainst) and df.building_isitemfree(i)
            }
                bld = df.building_alloc(:Well)
                t = df.map_tile_at((r.x1+r.x2)/2, (r.y1+r.y2)/2, r.z1)
                df.building_position(bld, t)
                df.building_construct(bld, [block, mecha, bucket, chain])
                r.misc[:bld_id] = bld.id
                @tasks << [:makeroom, r]
                true
            end
        end

        def build_furniture(f)
            return if f[:queue_build]
            ws = FurnitureWorkshop[f[:item]] ||= :Masons
            mod = FurnitureOrder[f[:item]] ||= "Construct#{f[:item].to_s.capitalize}".to_sym
            ensure_workshop(ws)
            add_manager_order(mod)
            f[:queue_build] = true
        end

        def ensure_workshop(subtype)
            if not ws = @rooms.find { |r| r.type == :workshop and r.subtype == subtype } or ws.status == :plan
                ws ||= @rooms.find { |r| r.type == :workshop and not r.subtype and r.status == :plan }
                ws.subtype = subtype
                case subtype
                when :ManagersOffice, :BookkeepersOffice
                    wantdig(ws)
                else
                    digroom(ws)
                    df.add_announcement("AI: new workshop #{subtype}", 7, false) { |ann| ann.pos = [ws.x+1, ws.y+1, ws.z] }
                end
            end
            ws
        end

        def ensure_stockpile(sptype, faster=false)
            if sp = @rooms.find { |r| r.type == :stockpile and r.subtype == sptype and not r.misc[:workshop] }
                ensure_stockpile(:food) if sptype != :food  # XXX make sure we dig food first
                wantdig(sp, faster)
            end
        end

        def try_construct_workshop(r)
            case r.subtype
            when :ManagersOffice, :BookkeepersOffice
                r.layout.each { |f|
                    @tasks << [:furnish, r, f] if f[:makeroom]
                }
                true
            when :Dyers
                # barrel, bucket
                if barrel = df.world.items.other[:BARREL].find { |i|
                        i.kind_of?(DFHack::ItemBarrelst) and df.building_isitemfree(i) and not i.itemrefs.find { |ir| ir.kind_of?(DFHack::GeneralRefContainsItemst) }
                } and bucket = df.world.items.other[:BUCKET].find { |i|
                        i.kind_of?(DFHack::ItemBucketst) and df.building_isitemfree(i) and not i.itemrefs.find { |ir| ir.kind_of?(DFHack::GeneralRefContainsItemst) }
                }
                    bld = df.building_alloc(:Workshop, r.subtype)
                    df.building_position(bld, r)
                    df.building_construct(bld, [barrel, bucket])
                    r.misc[:bld_id] = bld.id
                    @tasks << [:checkconstruct, r]
                    true
                end
            when :Ashery
                # block, barrel, bucket
                if block = df.world.items.other[:BLOCKS].find { |i|
                        i.kind_of?(DFHack::ItemBlocksst) and df.building_isitemfree(i)
                } and barrel = df.world.items.other[:BARREL].find { |i|
                        i.kind_of?(DFHack::ItemBarrelst) and df.building_isitemfree(i) and not i.itemrefs.find { |ir| ir.kind_of?(DFHack::GeneralRefContainsItemst) }
                } and bucket = df.world.items.other[:BUCKET].find { |i|
                        i.kind_of?(DFHack::ItemBucketst) and df.building_isitemfree(i) and not i.itemrefs.find { |ir| ir.kind_of?(DFHack::GeneralRefContainsItemst) }
                }
                    bld = df.building_alloc(:Workshop, r.subtype)
                    df.building_position(bld, r)
                    df.building_construct(bld, [block, barrel, bucket])
                    r.misc[:bld_id] = bld.id
                    @tasks << [:checkconstruct, r]
                    true
                end
            when :MetalsmithsForge
                # anvil, boulder
                if anvil = df.world.items.other[:ANVIL].find { |i|
                        i.kind_of?(DFHack::ItemAnvilst) and df.building_isitemfree(i) and i.isTemperatureSafe(11640)
                } and bould = df.world.items.other[:BOULDER].find { |i|
                        i.kind_of?(DFHack::ItemBoulderst) and df.building_isitemfree(i) and !df.ui.economic_stone[i.mat_index] and i.isTemperatureSafe(11640)
                }
                    bld = df.building_alloc(:Workshop, r.subtype)
                    df.building_position(bld, r)
                    df.building_construct(bld, [anvil, bould])
                    r.misc[:bld_id] = bld.id
                    @tasks << [:checkconstruct, r]
                    true
                end
            when :WoodFurnace, :Smelter
                # firesafe boulder
                if bould = df.world.items.other[:BOULDER].find { |i|
                        i.kind_of?(DFHack::ItemBoulderst) and df.building_isitemfree(i) and !df.ui.economic_stone[i.mat_index] and i.isTemperatureSafe(11640)
                }
                    bld = df.building_alloc(:Furnace, r.subtype)
                    df.building_position(bld, r)
                    df.building_construct(bld, [bould])
                    r.misc[:bld_id] = bld.id
                    @tasks << [:checkconstruct, r]
                    true
                end
            else
                # any non-eco boulder
                if bould = df.map_tile_at(r).mapblock.items_tg.find { |i|
                        # check map_block.items first
                        i.kind_of?(DFHack::ItemBoulderst) and df.building_isitemfree(i) and
                        !df.ui.economic_stone[i.mat_index] and
                        i.pos.x >= r.x1 and i.pos.x <= r.x2 and i.pos.y >= r.y1 and i.pos.y <= r.y2
                } || df.world.items.other[:BOULDER].find { |i|
                        i.kind_of?(DFHack::ItemBoulderst) and df.building_isitemfree(i) and
                        !df.ui.economic_stone[i.mat_index]
                }
                    bld = df.building_alloc(:Workshop, r.subtype)
                    df.building_position(bld, r)
                    df.building_construct(bld, [bould])
                    r.misc[:bld_id] = bld.id
                    @tasks << [:checkconstruct, r]
                    true
                # XXX else quarry?
                end
            end
        end

        def construct_stockpile(r)
            bld = df.building_alloc(:Stockpile)
            df.building_position(bld, [r.x1, r.y1, r.z], r.w, r.h)
            bld.room.extents = df.malloc(r.w*r.h)
            bld.room.x = r.x1
            bld.room.y = r.y1
            bld.room.width = r.w
            bld.room.height = r.h
            r.w.times { |x| r.h.times { |y| bld.room.extents[x+r.w*y] = 1 } }
            df.building_construct_abstract(bld)
            r.misc[:bld_id] = bld.id
            furnish_room(r)

            setup_stockpile_settings(r, bld)

            if bld.max_bins > 8
                add_manager_order(:ConstructBin, 8)
            end
            if bld.max_barrels > 8
                add_manager_order(:MakeBarrel, 8)
            end

            if r.misc[:workshop] or r.misc[:secondary]
                ensure_stockpile(r.subtype)
                if main = @rooms.find { |o| o.type == :stockpile and o.subtype == r.subtype and not o.misc[:workshop] and not o.misc[:secondary]} and mb = main.dfbuilding
                    bld, mb = mb, bld if r.misc[:secondary]
                    mb.give_to << bld
                    bld.take_from << mb
                end
            else
                @rooms.each { |o|
                    if o.type == :stockpile and o.subtype == r.subtype and (o.misc[:workshop] or o.misc[:secondary]) and sub = o.dfbuilding
                        bld, sub = sub, bld if o.misc[:secondary]
                        bld.give_to << sub
                        sub.take_from << bld
                    end
                }
            end
        end

        def setup_stockpile_settings(r, bld)
            case r.subtype
            when :stone
                bld.settings.flags.stone = true
                if r.misc[:workshop] and r.misc[:workshop].subtype == :Masons
                    df.world.raws.inorganics.length.times { |i| bld.settings.stone[i] = (df.ui.economic_stone[i] ? 0 : 1) }
                else
                    df.world.raws.inorganics.length.times { |i| bld.settings.stone[i] = 1 }
                end
                bld.max_wheelbarrows = 1 if r.w > 1 and r.h > 1
            when :wood
                bld.settings.flags.wood = true
                df.world.raws.plants.all.length.times { |i| bld.settings.wood[i] = 1 }
            when :furniture, :goods, :ammo, :weapons, :armor
                case r.subtype
                when :furniture
                    bld.settings.flags.furniture = true
                    s = bld.settings.furniture
                    s.sand_bags = true
                    60.times { |i| s.type[i] = true }   # 33
                when :goods
                    bld.settings.flags.goods = true
                    s = bld.settings.finished_goods
                    150.times { |i| s.type[i] = true }  # 112 (== refuse)
                when :ammo
                    bld.settings.flags.ammo = true
                    s = bld.settings.ammo
                    10.times { |i| s.type[i] = true }   # 3
                when :weapons
                    bld.settings.flags.weapons = true
                    s = bld.settings.weapons
                    40.times { |i| s.weapon_type[i] = true }    # 24
                    20.times { |i| s.trapcomp_type[i] = true }  # 5
                    s.usable = true
                    s.unusable = true
                when :armor
                    bld.settings.flags.armor = true
                    s = bld.settings.armor
                    20.times { |i| s.body[i] = true }   # 12
                    20.times { |i| s.head[i] = true }   # 8
                    20.times { |i| s.feet[i] = true }   # 6
                    20.times { |i| s.hands[i] = true }  # 3
                    20.times { |i| s.legs[i] = true }   # 9
                    20.times { |i| s.shield[i] = true } # 9
                    s.usable = true
                    s.unusable = true
                end
                bld.max_bins = r.w*r.h
                30.times { |i| s.other_mats[i] = true }    # 10
                df.world.raws.inorganics.length.times { |i| s.mats[i] = true }
                s.quality_core.map! { true }
                s.quality_total.map! { true }
            when :animals
                bld.settings.flags.animals = true
                bld.settings.animals.animals_empty_cages = true
                bld.settings.animals.animals_empty_traps = true
                df.world.raws.creatures.all.length.times { |i| bld.settings.animals.enabled[i] = true }
            when :refuse, :corpses
                bld.settings.flags.refuse = true
                bld.settings.refuse.fresh_raw_hide = false
                bld.settings.refuse.rotten_raw_hide = true
                t = bld.settings.refuse.type
                150.times { |i| t.type[i] = true }  # 112, ItemType enum + other stuff
                if r.misc[:workshop] and r.misc[:workshop].subtype == :Craftsdwarfs
                    df.world.raws.creatures.all.length.times { |i|
                        t.corpses[i] = t.body_parts[i] = t.hair[i] = false
                        t.skulls[i] = t.bones[i] = t.shells[i] = t.teeth[i] = t.horns[i] = true
                    }
                elsif r.subtype == :corpses
                    df.world.raws.creatures.all.length.times { |i|
                        t.corpses[i] = true
                        t.body_parts[i] = t.skulls[i] = t.bones[i] = t.hair[i] =
                            t.shells[i] = t.teeth[i] = t.horns[i] = false
                    }
                else
                    df.world.raws.creatures.all.length.times { |i|
                        t.corpses[i] = false
                        t.body_parts[i] = t.skulls[i] = t.bones[i] = t.hair[i] =
                            t.shells[i] = t.teeth[i] = t.horns[i] = true
                    }
                end
            when :food
                bld.settings.flags.food = true
                bld.settings.food.prepared_meals = true
                bld.max_barrels = r.w*r.h
                t = bld.settings.food.type
                if r.misc[:workshop] and r.misc[:workshop].type == :farmplot and r.subtype == :food
                    df.world.raws.mat_table.organic_types[:Seed].length.times { |i| t.seeds[i] = true }
                elsif r.misc[:workshop] and r.misc[:workshop].type == :Farmers
                    df.world.raws.mat_table.organic_types[:Plants].length.times { |i| t.plants[i] = true }
                    df.world.raws.mat_table.organic_types[:Leaf].length.times { |i| t.leaves[i] = true }
                elsif r.misc[:workshop] and r.misc[:workshop].type == :Still
                    df.world.raws.mat_table.organic_types[:Plants].length.times { |i| t.plants[i] = true }
                elsif r.misc[:workshop] and r.misc[:workshop].type == :Fishery
                    df.world.raws.mat_table.organic_types[:UnpreparedFish].length.times { |i| t.unprepared_fish[i] = true }
                else
                    df.world.raws.mat_table.organic_types[:Meat          ].length.times { |i| t.meat[i]            = true }    # XXX very big (10588)
                    df.world.raws.mat_table.organic_types[:Fish          ].length.times { |i| t.fish[i]            = true }
                    df.world.raws.mat_table.organic_types[:UnpreparedFish].length.times { |i| t.unprepared_fish[i] = true }
                    df.world.raws.mat_table.organic_types[:Eggs          ].length.times { |i| t.egg[i]             = true }
                    df.world.raws.mat_table.organic_types[:Plants        ].length.times { |i| t.plants[i]          = true }
                    df.world.raws.mat_table.organic_types[:PlantDrink    ].length.times { |i| t.drink_plant[i]     = true }
                    df.world.raws.mat_table.organic_types[:CreatureDrink ].length.times { |i| t.drink_animal[i]    = true }
                    df.world.raws.mat_table.organic_types[:PlantCheese   ].length.times { |i| t.cheese_plant[i]    = true }
                    df.world.raws.mat_table.organic_types[:CreatureCheese].length.times { |i| t.cheese_animal[i]   = true }
                    df.world.raws.mat_table.organic_types[:Seed          ].length.times { |i| t.seeds[i]           = true }
                    df.world.raws.mat_table.organic_types[:Leaf          ].length.times { |i| t.leaves[i]          = true }
                    df.world.raws.mat_table.organic_types[:PlantPowder   ].length.times { |i| t.powder_plant[i]    = true }
                    df.world.raws.mat_table.organic_types[:CreaturePowder].length.times { |i| t.powder_creature[i] = true }
                    df.world.raws.mat_table.organic_types[:Glob          ].length.times { |i| t.glob[i]            = true }
                    df.world.raws.mat_table.organic_types[:Paste         ].length.times { |i| t.glob_paste[i]      = true }
                    df.world.raws.mat_table.organic_types[:Pressed       ].length.times { |i| t.glob_pressed[i]    = true }
                    df.world.raws.mat_table.organic_types[:PlantLiquid   ].length.times { |i| t.liquid_plant[i]    = true }
                    df.world.raws.mat_table.organic_types[:CreatureLiquid].length.times { |i| t.liquid_animal[i]   = true }
                    df.world.raws.mat_table.organic_types[:MiscLiquid    ].length.times { |i| t.liquid_misc[i]     = true }
                end
            when :cloth
                bld.settings.flags.cloth = true
                bld.max_bins = r.w*r.h
                t = bld.settings.cloth
                if r.misc[:workshop] and r.misc[:workshop].subtype == :Loom
                    df.world.raws.mat_table.organic_types[:Silk       ].length.times { |i| t.thread_silk[i]  = true ; t.cloth_silk[i]  = false }
                    df.world.raws.mat_table.organic_types[:PlantFiber ].length.times { |i| t.thread_plant[i] = true ; t.cloth_plant[i] = false }
                    df.world.raws.mat_table.organic_types[:Yarn       ].length.times { |i| t.thread_yarn[i]  = true ; t.cloth_yarn[i]  = false }
                    df.world.raws.mat_table.organic_types[:MetalThread].length.times { |i| t.thread_metal[i] = false; t.cloth_metal[i] = false }
                elsif r.misc[:workshop] and r.misc[:workshop].subtype == :Clothiers
                    df.world.raws.mat_table.organic_types[:Silk       ].length.times { |i| t.thread_silk[i]  = false ; t.cloth_silk[i]  = true }
                    df.world.raws.mat_table.organic_types[:PlantFiber ].length.times { |i| t.thread_plant[i] = false ; t.cloth_plant[i] = true }
                    df.world.raws.mat_table.organic_types[:Yarn       ].length.times { |i| t.thread_yarn[i]  = false ; t.cloth_yarn[i]  = true }
                    df.world.raws.mat_table.organic_types[:MetalThread].length.times { |i| t.thread_metal[i] = false ; t.cloth_metal[i] = true }
                else
                    df.world.raws.mat_table.organic_types[:Silk       ].length.times { |i| t.thread_silk[i]  = t.cloth_silk[i]  = true }
                    df.world.raws.mat_table.organic_types[:PlantFiber ].length.times { |i| t.thread_plant[i] = t.cloth_plant[i] = true }
                    df.world.raws.mat_table.organic_types[:Yarn       ].length.times { |i| t.thread_yarn[i]  = t.cloth_yarn[i]  = true }
                    df.world.raws.mat_table.organic_types[:MetalThread].length.times { |i| t.thread_metal[i] = t.cloth_metal[i] = true }
                end
            when :leather
                bld.settings.flags.leather = true
                bld.max_bins = r.w*r.h
                df.world.raws.mat_table.organic_types[:Leather].length.times { |i| bld.settings.leather[i] = true }
            when :gems
                bld.settings.flags.gems = true
                t = bld.settings.gems
                if r.misc[:workshop] and r.misc[:workshop].subtype == :Jewelers
                    df.world.raws.mat_table.builtin.length.times { |i| t.rough_other_mats[i] = t.cut_other_mats[i] = false }
                    df.world.raws.inorganics.length.times { |i| t.rough_mats[i] = true ; t.cut_mats[i] = false }
                else
                    df.world.raws.mat_table.builtin.length.times { |i| t.rough_other_mats[i] = t.cut_other_mats[i] = true }
                    df.world.raws.inorganics.length.times { |i| t.rough_mats[i] = t.cut_mats[i] = true }
                end
            when :bars
                bld.settings.flags.bars = true
                bld.max_bins = r.w*r.h
                df.world.raws.inorganics.length.times { |i| bld.settings.bars_mats[i] = bld.settings.blocks_mats[i] = true }
                10.times { |i| bld.settings.bars_other_mats[i] = bld.settings.blocks_other_mats[i] = true }
                # bars_other = 5 (coal/potash/ash/pearlash/soap)     blocks_other = 4 (greenglass/clearglass/crystalglass/wood)
            when :coins
                bld.settings.flags.coins = true
                df.world.raws.inorganics.length.times { |i| bld.settings.coins[i] = true }
            end
        end

        def construct_farmplot(r)
            bld = df.building_alloc(:FarmPlot)
            df.building_position(bld, [r.x1, r.y1, r.z], r.w, r.h)
            df.building_construct(bld, [])
            r.misc[:bld_id] = bld.id
            furnish_room(r)
            if st = @rooms.find { |_r| _r.type == :stockpile and _r.misc[:workshop] == r }
                digroom(st)
            end
            @tasks << [:setup_farmplot, r]
        end

        def construct_well(r)
        end

        def try_digcistern(r)
            ((r.x1-1)..(r.x2+1)).each { |x|
                ((r.y1-1)..(r.y2+1)).each { |y|
                    z = r.z1
                    next unless t = df.map_tile_at(x, y, z)
                }
            }

            issmooth = lambda { |t|
                next true if t.shape_basic == :Open
                next true if t.tilemat == :SOIL
                next true if t.shape_basic == :Wall and t.caption =~ /pillar|smooth/i
            }

            cnt = 0
            acc_y = r.accesspath[0].y   # XXX hardcoded layout..
            (r.z1..r.z2).each { |z|
                ((r.x1-1)..(r.x2+1)).each { |x|
                    ((r.y1-1)..(r.y2+1)).each { |y|
                        next unless t = df.map_tile_at(x, y, z)
                        case t.shape_basic
                        when :Wall
                            t.dig :Smooth
                        when :Floor
                            if z == r.z1
                                t.dig :Smooth if t.shape_basic == :Wall or t.shape_basic == :Floor
                                next
                            end

                            next unless nt20 = df.map_tile_at(x+1, y-1, z)
                            next unless nt21 = df.map_tile_at(x+1, y, z)
                            next unless nt22 = df.map_tile_at(x+1, y+1, z)
                            if issmooth[nt20] and issmooth[nt21] and issmooth[nt22]
                                next unless nt01 = df.map_tile_at(x-1, y, z)
                                if nt01.shape_basic == :Floor
                                    t.dig :Channel
                                else
                                    next unless nt10 = df.map_tile_at(x, y-1, z)
                                    next unless nt12 = df.map_tile_at(x, y+1, z)
                                    t.dig :Channel if (y > acc_y ? issmooth[nt12] : issmooth[nt10])
                                end
                            end
                        when :Open
                            cnt += 1 if x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2
                        end
                    }
                }
            }

            dug = (cnt == r.w*r.h*(r.h_z-1))
            # TODO remove items, fill with water

            dug
        end

        def try_setup_farmplot(r)
            bld = r.dfbuilding
            if not bld
                puts "MOO"
                return true
            end
            return if bld.getBuildStage < bld.getMaxBuildStage

            if r.subtype == :food
                pid = df.world.raws.plants.all.index { |p| p.id == 'MUSHROOM_HELMET_PLUMP' }

                bld.plant_id[0] = pid
                bld.plant_id[1] = pid
                bld.plant_id[2] = pid
                bld.plant_id[3] = pid
            else
                puts "MUU farm settings"
            end

            true
        end

        def try_makeroom(r)
            bld = r.dfbuilding
            if not bld
                puts "AI: destroyed building ? #{r.inspect}"
                return true
            end
            return if bld.getBuildStage < bld.getMaxBuildStage
            debug "makeroom #{@rooms.index(r)} #{r.type} #{r.subtype}"

            df.free(bld.room.extents._getp) if bld.room.extents
            bld.room.extents = df.malloc((r.w+2)*(r.h+2))
            bld.room.x = r.x1-1
            bld.room.y = r.y1-1
            bld.room.width = r.w+2
            bld.room.height = r.h+2
            set_ext = lambda { |x, y, v| bld.room.extents[bld.room.width*(y-bld.room.y)+(x-bld.room.x)] = v }
            (r.x1-1 .. r.x2+1).each { |rx| (r.y1-1 .. r.y2+1).each { |ry|
                if df.map_tile_at(rx, ry, r.z).shape == :WALL
                    set_ext[rx, ry, 2]
                else
                    set_ext[rx, ry, 3]
                end
            } }
            r.layout.each { |d|
                next if d[:item] != :door
                x = r.x1 + d[:x].to_i
                y = r.y1 + d[:y].to_i
                set_ext[x, y, 0]
                # tile in front of the door tile is 4   (TODO door in corner...)
                set_ext[x+1, y, 4] if x < r.x1
                set_ext[x-1, y, 4] if x > r.x2
                set_ext[x, y+1, 4] if y < r.y1
                set_ext[x, y-1, 4] if y > r.y2
            }
            bld.is_room = 1

            set_owner(r, r.owner)
            furnish_room(r)
            if r.type == :dininghall
                bld.table_flags.meeting_hall = true
                @rooms.each { |r| wantdig(r) if r.type == :well }
            end
            true
        end

        def try_endconstruct(r)
            bld = r.dfbuilding
            return if bld and bld.getBuildStage < bld.getMaxBuildStage
            furnish_room(r)
            true
        end

        def add_manager_order(order, amount=1)
            debug "add_manager #{order} #{amount}"
            if not o = df.world.manager_orders.find { |_o| _o.job_type == order and _o.amount_total < 4 }
                o = DFHack::ManagerOrder.cpp_new(:job_type => order, :unk_2 => -1, :item_subtype => -1,
                        :mat_type => -1, :mat_index => -1, :hist_figure_id => -1, :amount_left => amount, :amount_total => amount)
                df.world.manager_orders << o
            else
                o.amount_total += amount
                o.amount_left += amount
            end

            case order
            when :ConstructBed, :MakeBarrel, :MakeBucket, :ConstructBin  # wood
                o.material_category.wood = true
                df.cuttrees(:any, amount, true)     # TODO generic work input
            else
                o.mat_type = 0
            end
        end

        attr_accessor :fort_entrance, :rooms, :corridors
        def setup_blueprint
            # TODO use existing fort facilities (so we can relay the user or continue from a save)
            puts 'AI: setting up fort blueprint'
            scan_fort_entrance
            debug 'blueprint found entrance'
            scan_fort_body
            debug 'blueprint found body'
            setup_blueprint_rooms
            debug 'blueprint found rooms'
        end

        # search a valid tile for fortress entrance
        def scan_fort_entrance
            # map center
            cx = df.world.map.x_count / 2
            cy = df.world.map.y_count / 2
            rangex = (-cx..cx).sort_by { |_x| _x.abs }
            rangey = (-cy..cy).sort_by { |_y| _y.abs }
            rangez = (0...df.world.map.z_count).to_a.reverse

            bestdist = 100000
            off = rangex.map { |_x|
                # test the whole map for 4x3 clean spots
                dy = rangey.find { |_y|
                    # can break because rangey is sorted by dist
                    break if _x.abs + _y.abs > bestdist
                    cz = rangez.find { |z|
                        t = df.map_tile_at(cx+_x, cy+_y, z) and t.shape == :FLOOR
                    }
                    next if not cz
                    (-1..2).all? { |__x|
                        (-1..1).all? { |__y|
                            t = df.map_tile_at(cx+_x+__x, cy+_y+__y, cz-1) and t.shape == :WALL and
                            tt = df.map_tile_at(cx+_x+__x, cy+_y+__y, cz) and tt.shape == :FLOOR and tt.designation.flow_size == 0 and not tt.designation.hidden and not df.building_find(tt)
                        }
                    }
                }
                bestdist = [_x.abs + dy.abs, bestdist].min if dy
                [_x, dy] if dy
                # find the closest to the center of the map
            }.compact.sort_by { |dx, dy| dx.abs + dy.abs }.first

            if off
                cx += off[0]
                cy += off[1]
            else
                puts 'AI: cant find fortress entrance spot'
            end
            cz = rangez.find { |z| t = df.map_tile_at(cx, cy, z) and t.shape == :FLOOR }

            @fort_entrance = Corridor.new(cx, cx+1, cy, cy, cz, cz)
        end

        # search how much we need to dig to find a spot for the full fortress body
        # here we cheat and work as if the map was fully reveal()ed
        def scan_fort_body
            # use a hardcoded fort layout
            cx, cy, cz = @fort_entrance.x, @fort_entrance.y, @fort_entrance.z
            @fort_entrance.z1 = (0..cz).to_a.reverse.find { |cz1|
                (-35..35).all? { |dx|
                    (-22..22).all? { |dy|
                        (-5..1).all? { |dz|
                            # ensure at least stockpiles are in rock layer for the masons
                            t = df.map_tile_at(cx+dx, cy+dy, cz1+dz) and t.shape == :WALL and
                            not t.designation.water_table and (t.tilemat == :STONE or t.tilemat == :MINERAL or (dz > -1 and t.tilemat == :SOIL))
                        }
                    }
                }
            }

            raise 'we need more minerals' if not @fort_entrance.z1
        end

        # assign rooms in the space found by scan_fort_*
        def setup_blueprint_rooms
            @rooms = []
            @corridors = []

            # hardcoded layout
            @corridors << @fort_entrance

            fx = @fort_entrance.x1
            fy = @fort_entrance.y1

            fz = @fort_entrance.z1
            setup_blueprint_workshops(fx, fy, fz, [@fort_entrance])
            
            fz = @fort_entrance.z1 -= 1
            setup_blueprint_utilities(fx, fy, fz, [@fort_entrance])
            
            fz = @fort_entrance.z1 -= 1
            setup_blueprint_stockpiles(fx, fy, fz, [@fort_entrance])
            
            2.times {
                fz = @fort_entrance.z1 -= 1
                setup_blueprint_bedrooms(fx, fy, fz, [@fort_entrance])
            }
        end

        def setup_blueprint_workshops(fx, fy, fz, entr)
            corridor_center = Corridor.new(fx-2, fx+2, fy-1, fy+1, fz, fz) 
            corridor_center.accesspath = entr
            @corridors << corridor_center

            # Quern, Millstone, Siege, Custom/soapmaker, Custom/screwpress
            # GlassFurnace, Kiln, magma workshops/furnaces, other nobles offices
            types = [:Still,:Kitchen, :Fishery,:Butchers, :Leatherworks,:Tanners,
                :Loom,:Clothiers, :Dyers,:Bowyers, nil,nil]
            types += [:Masons,:Carpenters, :Mechanics,:Farmers, :Craftsdwarfs,:Jewelers,
                :Ashery,:MetalsmithsForge, :WoodFurnace,:Smelter, :ManagersOffice,:BookkeepersOffice]

            [-1, 1].each { |dirx|
                prev_corx = corridor_center
                ocx = fx + dirx*3
                (1..6).each { |dx|
                    # segments of the big central horizontal corridor
                    cx = fx + dirx*(4*dx-1)
                    if dx <= 5
                        cor_x = Corridor.new(ocx, cx, fy-1, fy+1, fz, fz)
                        cor_x.accesspath = [prev_corx]
                        @corridors << cor_x
                    else
                        # last 2 workshops of the row (offices etc) get only a narrow/direct corridor
                        cor_x = Corridor.new(fx+dirx*3, cx, fy, fy, fz, fz)
                        cor_x.accesspath = [corridor_center]
                        @corridors << cor_x
                        cor_x = Corridor.new(cx-dirx*3, cx, fy-1, fy+1, fz, fz)
                        cor_x.accesspath = [@corridors.last]
                        @corridors << cor_x
                    end
                    prev_corx = cor_x
                    ocx = cx+dirx

                    @rooms << Room.new(:workshop, types.shift, cx-1, cx+1, fy-5, fy-3, fz)
                    @rooms << Room.new(:workshop, types.shift, cx-1, cx+1, fy+3, fy+5, fz)
                    @rooms[-2, 2].each { |r|
                        r.accesspath = [cor_x]
                        r.layout << {:item => :door, :x => 1, :y => 1-2*(r.y<=>fy)}
                    }
                }
            }
            @rooms.each { |r|
                next if r.type != :workshop
                case r.subtype
                when :ManagersOffice, :BookkeepersOffice
                    r.layout << {:item => :chair, :x => 1, :y => 1, :makeroom => true}
                end
            }
        end

        def setup_blueprint_stockpiles(fx, fy, fz, entr)
            corridor_center = Corridor.new(fx-2, fx+2, fy-1, fy+1, fz, fz) 
            corridor_center.accesspath = entr
            @corridors << corridor_center

            types = [:wood,:stone, :furniture,:goods, :gems,:weapons, :refuse,:corpses]
            types += [:food,:ammo, :cloth,:leather, :bars,:armor, :animals,:coins]

            # TODO side stairs to workshop level ?
            [-1, 1].each { |dirx|
                prev_corx = corridor_center
                ocx = fx + dirx*3
                (1..4).each { |dx|
                    # segments of the big central horizontal corridor
                    cx = fx + dirx*(8*dx-4)
                    cor_x = Corridor.new(ocx, cx+dirx, fy-1, fy+1, fz, fz)
                    cor_x.accesspath = [prev_corx]
                    @corridors << cor_x
                    prev_corx = cor_x
                    ocx = cx+2*dirx

                    t0, t1 = types.shift, types.shift
                    @rooms << Room.new(:stockpile, t0, cx-3, cx+3, fy-5, fy-3, fz)
                    @rooms << Room.new(:stockpile, t1, cx-3, cx+3, fy+3, fy+5, fz)
                    @rooms[-2, 2].each { |r|
                        r.accesspath = [cor_x]
                        r.layout << {:item => :door, :x => 2, :y => 1-2*(r.y<=>fy)}
                        r.layout << {:item => :door, :x => 4, :y => 1-2*(r.y<=>fy)}
                    }
                    @rooms << Room.new(:stockpile, t0, cx-3, cx+3, fy-11, fy-5, fz)
                    @rooms << Room.new(:stockpile, t1, cx-3, cx+3, fy+5, fy+11, fz)
                    @rooms[-2, 2].each { |r| r.misc[:secondary] = true }
                }
            }
        end

        def setup_blueprint_utilities(fx, fy, fz, entr)
            corridor_center = Corridor.new(fx-2, fx+2, fy-1, fy+1, fz, fz) 
            corridor_center.accesspath = entr
            @corridors << corridor_center

            # dining halls
            # TODO start with a 1/4 dining hall, expand it afterwards
            ocx = fx-2
            old_cor = corridor_center

            [0, 1].each { |ax|
                cor = Corridor.new(ocx-1, fx-ax*12-6, fy-1, fy+1, fz, fz)
                cor.accesspath = [old_cor]
                @corridors << cor
                ocx = fx-ax*12-6
                old_cor = cor

                [-1, 1].each { |dy|
                    dinner = Room.new(:dininghall, nil, fx-ax*12-4-8, fx-ax*12-4, fy+dy*9, fy+dy*3, fz)
                    dinner.layout << {:item => :door, :x => 6, :y => (dy>0 ? -1 : 7)}
                    dinner.layout << {:item => :pillar, :x => 2, :y => 3}
                    dinner.layout << {:item => :pillar, :x => 6, :y => 3}
                    [4,3,5,2,6,1,7].each { |dx|
                        [-1, 1].each { |sy|
                            dinner.layout << {:item => :table, :x => dx, :y => 3+dy*sy*1, :ignore => true, :users => []}
                            dinner.layout << {:item => :chair, :x => dx, :y => 3+dy*sy*2, :ignore => true, :users => []}
                        }
                    }
                    t0 = dinner.layout.find { |f| f[:item] == :table }
                    t0.delete :ignore
                    t0[:makeroom] = true
                    dinner.accesspath = [cor]
                    @rooms << dinner
                }
            }

            # well
            # in the hole from bedrooms
            # top room (actual well)
            cor = Corridor.new(ocx-1, fx-26, fy-1, fy+1, fz, fz)
            cor.accesspath = [old_cor]
            @corridors << cor
            
            cx = fx-32
            well = Room.new(:well, :well, cx-4, cx+4, fy-4, fy+4, fz)
            well.layout << {:item => :well, :x => 4, :y => 4}
            well.layout << {:item => :door, :x => 9, :y => 3}
            well.layout << {:item => :door, :x => 9, :y => 5}
            well.accesspath = [cor]
            @rooms << well

            # cistern
            cist_corr = Corridor.new(cx-8, cx-8, fy, fy, fz-3, fz)
            # TODO cuttree / drain pool there
            # TODO path to water source
            cist_corr.z2 += 1 until df.map_tile_at(cx-8, fy, cist_corr.z2).shape_basic != :Wall

            cist = Room.new(:well, :cistern, cx-7, cx+1, fy-1, fy+1, fz-1)
            cist.z1 -= 2
            cist.accesspath = [cist_corr]
            @rooms << cist


            # farm plots
            nrfarms = 4
            cx = fx+4*6-1       # end of workshop corridor (last ws door)
            cy = fy
            cz = @rooms.find { |r| r.type == :workshop }.z1
            farm_stairs = Corridor.new(cx+2, cx+2, cy, cy, cz, cz)
            ws_cor = @corridors.find { |_c| _c.x1 < cx and _c.x2 >= cx and _c.y1 <= cy and _c.y2 >= cy and _c.z1 <= cz and _c.z2 >= cz }
            raise "cannot connect farm to workshop corridor" if not ws_cor
            farm_stairs.accesspath = [ws_cor]
            farm_stairs.layout << {:item => :door, :x => -1}
            cx += 3
            cz2 = (cz...fort_entrance.z2).find { |z|
                (-1..(nrfarms*3)).all? { |dx|
                    (-6..6).all? { |dy|
                        t = df.map_tile_at(cx+dx, cy+dy, z) and t.shape == :WALL and t.tilemat == :SOIL
                    }
                }
            }
            cz2 ||= cz  # TODO irrigation
            farm_stairs.z2 = cz2
            cor = Corridor.new(cx, cx+1, cy, cy, cz2, cz2)
            cor.accesspath = [farm_stairs]
            types = [:food, :cloth]
            [-1, 1].each { |dy|
                st = types.shift
                nrfarms.times { |dx|
                    r = Room.new(:farmplot, st, cx+3*dx, cx+3*dx+2, cy+dy*2, cy+dy*5, cz2)
                    r.misc[:users] = []
                    if dx == 0
                        r.layout << {:item => :door, :x => 1, :y => (dy>0 ? -1 : 4)}
                        r.accesspath = [cor]
                    else
                        r.accesspath = [@rooms.last]
                    end
                    @rooms << r
                }
            }
            # seeds stockpile
            r = Room.new(:stockpile, :food, cx+2, cx+4, cy, cy, cz2)
            r.misc[:workshop] = @rooms[-2*nrfarms]
            r.accesspath = [cor]
            @rooms << r


            # TODO
            # infirmary
            # cemetary
            # barracks
            # pastures
        end

        def setup_blueprint_bedrooms(fx, fy, fz, entr)
            corridor_center = Corridor.new(fx-2, fx+2, fy-1, fy+1, fz, fz) 
            corridor_center.accesspath = entr
            @corridors << corridor_center

            [-1, 1].each { |dirx|
                prev_corx = corridor_center
                ocx = fx + dirx*3
                (1..3).each { |dx|
                    # segments of the big central horizontal corridor
                    cx = fx + dirx*(11*dx-4)
                    cor_x = Corridor.new(ocx, cx, fy-1, fy+1, fz, fz)
                    cor_x.accesspath = [prev_corx]
                    @corridors << cor_x
                    prev_corx = cor_x
                    ocx = cx+dirx

                    [-1, 1].each { |diry|
                        prev_cory = cor_x
                        ocy = fy + diry*2
                        (1..5).each { |dy|
                            cy = fy + diry*4*dy
                            cor_y = Corridor.new(cx, cx-dirx*1, ocy, cy, fz, fz)
                            cor_y.accesspath = [prev_cory]
                            @corridors << cor_y
                            prev_cory = cor_y
                            ocy = cy+diry

                            @rooms << Room.new(:bedroom, nil, cx-dirx*5, cx-dirx*3, cy-1, cy+1, fz)
                            @rooms << Room.new(:bedroom, nil, cx+dirx*2, cx+dirx*4, cy-1, cy+1, fz)
                            @rooms[-2, 2].each { |r|
                                r.accesspath = [cor_y]
                                r.layout << {:item => :bed, :x => 1, :y => 1, :makeroom => true}
                                r.layout << {:item => :cabinet, :x => 1+(r.x<=>cx), :y => 1+diry}
                                r.layout << {:item => :door, :x => 1-2*(r.x<=>cx), :y => 1}
                            }
                        }
                    }
                }
            }
        end

        class Corridor
            attr_accessor :x1, :x2, :y1, :y2, :z1, :z2, :accesspath, :status, :layout, :type
            attr_accessor :owner, :subtype
            attr_accessor :misc
            def x; x1; end
            def y; y1; end
            def z; z1; end
            def w; x2-x1+1; end
            def h; y2-y1+1; end
            def h_z; z2-z1+1; end

            def initialize(x1, x2, y1, y2, z1, z2)
                @misc = {}
                @status = :plan
                @accesspath = []
                @layout = []
                @type = :corridor
                x1, x2 = x2, x1 if x1 > x2
                y1, y2 = y2, y1 if y1 > y2
                z1, z2 = z2, z1 if z1 > z2
                @x1, @x2, @y1, @y2, @z1, @z2 = x1, x2, y1, y2, z1, z2
            end

            def dig
                (@x1..@x2).each { |x| (@y1..@y2).each { |y| (@z1..@z2).each { |z|
                    if t = df.map_tile_at(x, y, z)
                        dm = dig_mode(t.x, t.y, t.z)
                        t.dig dm if dm == :DownStair or t.shape == :WALL or t.shape == :TREE
                    end
                } } }
                @layout.each { |d|
                    if t = df.map_tile_at(x1+d[:x].to_i, y1+d[:y].to_i, z1+d[:z].to_i)
                        dm = dig_mode(t.x, t.y, t.z)
                        case d[:item]
                        when :pillar
                            t.dig :Smooth
                        when :well
                            t.dig :Channel if t.shape_basic != :Open
                        else
                            t.dig dm if dm == :DownStair or t.shape == :WALL or t.shape == :TREE
                        end
                    end
                }
            end

            def dig_mode(x, y, z)
                return :Default if @type != :corridor
                wantup = wantdown = false
                wantup = true if z < z2 and x >= x1 and x <= x2 and y >= y1 and y <= y2
                wantdown = true if z > z1 and x >= x1 and x <= x2 and y >= y1 and y <= y2
                wantup = true if accesspath.find { |r|
                    r.x1 <= x and r.x2 >= x and r.y1 <= y and r.y2 >= y and r.z2 > z
                }
                wantdown = true if accesspath.find { |r|
                    r.x1 <= x and r.x2 >= x and r.y1 <= y and r.y2 >= y and r.z1 < z
                }
                if wantup
                    wantdown ? :UpDownStair : :UpStair
                else
                    wantdown ? :DownStair : :Default
                end
            end

            def dug?
                holes = []
                @layout.each { |d|
                    if t = df.map_tile_at(x1+d[:x].to_i, y1+d[:y].to_i, z1+d[:z].to_i)
                        next holes << t if d[:item] == :pillar
                        return false if t.shape == :WALL
                    end
                }
                (@x1..@x2).each { |x| (@y1..@y2).each { |y| (@z1..@z2).each { |z|
                    if t = df.map_tile_at(x, y, z)
                        return false if t.shape == :WALL and not holes.find { |h| h.x == t.x and h.y == t.y and h.z == t.z }
                    end
                } } }
                true
            end
        end

        class Room < Corridor
            def initialize(type, subtype, x1, x2, y1, y2, z)
                super(x1, x2, y1, y2, z, z)
                @type = type
                @subtype = subtype
            end

            def dfbuilding
                df.building_find(misc[:bld_id]) if misc[:bld_id]
            end
        end
    end
end
