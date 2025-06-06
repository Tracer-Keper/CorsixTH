--[[ Copyright (c) 2009 Peter "Corsix" Cawley

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE. --]]

--! A `Humanoid` who is in the hospital for diagnosis and/or treatment.
class "Patient" (Humanoid)

---@type Patient
local Patient = _G["Patient"]

function Patient:Patient(...)
  self:Humanoid(...)
  self.hover_cursor = TheApp.gfx:loadMainCursor("patient")
  self.should_knock_on_doors = true
  self.treatment_history = {}
  self.going_home = false -- If set, the patient is going home.
  self.litter_countdown = nil -- If set, number of tiles to walk before attempting to drop litter.
  self.has_fallen = 1
  self.has_vomitted = 0
  self.action_string = ""
  self.cured = false
  self.infected = false
  self.pay_amount = 0
  -- To distinguish between actually being dead and having a nil hospital
  self.dead = false
  -- Is the patient reserved for a particular nurse when being vaccinated
  self.reserved_for = false
  self.vaccinated = false
  -- Has the patient been sent to the wrong room and needs redirecting
  self.needs_redirecting = false
  -- Indicates is currently some infected patient trying to infect this patient
  -- Prevents the situation when several infectors trying to infect the same victim
  self.under_infection_attempt = false
  -- Is the patient about to be vaccinated?
  self.vaccination_candidate = false
  -- Has the patient passed reception?
  self.has_passed_reception = false

  -- Is the patient trying to get to the toilet? ("yes", "no", or "no-toilets")
  self.going_to_toilet = "no"

  -- Health history in entries 1..SIZE (may not all exist at first). The "last"
  -- entry indicates last written entry, "(last+1) % SIZE" is the oldest entry.
  -- The "size" entry holds the length of the array (that is, SIZE).
  -- Variable gets automatically initialized on first day.
  self.health_history = nil
end

function Patient:onClick(ui, button)
  if button == "left" then
    if self.message_callback then
      self:message_callback()
    else
      local hospital = self.hospital or self.world:getLocalPlayerHospital()
      local epidemic = hospital and hospital.epidemic
      if epidemic and epidemic.vaccination_mode_active then
        epidemic:markForVaccination(self)
      else
        ui:addWindow(UIPatient(ui, self))
      end
    end
  elseif self.user_of then
    -- The object we're using is made invisible, as the animation contains both
    -- the humanoid and the object. Hence send the click onto the object.
    self.user_of:onClick(ui, button)
  elseif TheApp.config.debug_falling and button == "right" then
    -- Attempt to push patient over
    -- Currently debug-only, enable in config file for testing.
    -- Once confirmed working, the debugging flag can be removed.
    if not self.world:isPaused() and not (self.cured or self.dead or self.going_home)
         and math.random(1, 2) == 2 then
      self:falling(true)
    end
  end
  Humanoid.onClick(self, ui, button)
end

function Patient:setDisease(disease)
  self.disease = disease
  disease.initPatient(self)
  self.th:setPatientEffect(disease.effect or AnimationEffect.None)
  self.diagnosed = false
  self.diagnosis_progress = 0
  self.cure_rooms_visited = 0
  -- Copy list of diagnosis rooms
  -- (patient may visit these for diagnosis, if they exist in the hospital).
  self.available_diagnosis_rooms = {}
  for i, room in ipairs(self.disease.diagnosis_rooms) do
    self.available_diagnosis_rooms[i] = room
  end
  local company = math.random(1,12)
  if company < 4 then
    self.insurance_company = company
  end
  -- Randomise thirst and the need to visit the loo soon.
  -- Alien patients do not have the needed animations for these things, so exclude them
  if not self.disease.only_emergency then
    self.attributes["thirst"] = math.random()*0.2
    self.attributes["toilet_need"] = math.random()*0.2
  end
  self:updateDynamicInfo()
end

function Patient:changeDisease(new_disease)
  assert(not self.diagnosed, "Cannot change the disease of a diagnosed patient")
  -- These assertions should hold until handling of visual diseases is implemented.
  assert(self.disease.contagious, "Cannot change the disease of a patient who has a non-contagious disease")
  assert(new_disease.contagious, "Cannot change a disease to a non-contagious disease")

  local visited_rooms = {}

  -- Add all diagnosis room for the old disease.
  for _, room in ipairs(self.disease.diagnosis_rooms) do
    visited_rooms[room] = true
  end

  -- Disable the rooms not yet visited by the patient.
  for _, room in ipairs(self.available_diagnosis_rooms) do
    visited_rooms[room] = false
  end

  -- 'visited_rooms' is now diagnosis rooms that the patient has visited for the old disease.

  -- Compute unvisited rooms for the new disease.
  self.available_diagnosis_rooms = {}
  for _, room in ipairs(new_disease.diagnosis_rooms) do
    if not visited_rooms[room] then
      self.available_diagnosis_rooms[#self.available_diagnosis_rooms + 1] = room
    end
  end

  self.disease = new_disease -- Finally, make the patient carry the new disease.
end

--! Mark patient as being diagnosed.
function Patient:setDiagnosed()
  self.diagnosed = true
  self.treatment_history[#self.treatment_history + 1] = self.disease.name

  local window = self.world.ui:getWindow(UIPatient)
  if window and window.patient == self then
    window:updateInformation()
  end

  self:updateDynamicInfo()
end

--! Modifies the diagnosis progress of a patient.
-- incrementValue can be either positive or negative.
function Patient:modifyDiagnosisProgress(incrementValue)
  self.diagnosis_progress = math.min(self.hospital.policies["stop_procedure"],
    self.diagnosis_progress + incrementValue)
  self.diagnosis_progress = math.max(0.000, self.diagnosis_progress)
  local window = self.world.ui:getWindow(UIPatient)
  if window and window.patient == self then
    window:updateInformation()
  end
  self:updateDynamicInfo()
end

--! Updates the patients diagnostic progress based on the doctors skill
-- called when they are done using a diagnosis room
function Patient:completeDiagnosticStep(room)
  -- Base: depending on difficulty of disease as set in sam file
  -- tiredness reduces the chance of diagnosis if staff member is above 50% tired
  local multiplier = 1

  local expertise = self.world.map.level_config.expertise
  local diagnosis_difficulty = expertise[self.disease.expertise_id].MaxDiagDiff / 1000
  local diagnosis_base = 0.4 * (1 - diagnosis_difficulty)
  local diagnosis_bonus = 0.4

  -- Did the staff member manage to leave the room before the patient had
  -- a chance to get diagnosed? Then use a default middle value.
  if room.staff_member then
    local fatigue = room.staff_member:getAttribute("fatigue")

    -- Bonus: based on skill and attn to detail (with some randomness).
    -- additional bonus if the staff member is highly skilled / consultant
    -- tiredness reduces the chance of diagnosis if staff member is above 50% tired
    if room.staff_member.profile.skill >= 0.9 then
      multiplier = math.random(1, 5) * (1 - (fatigue -0.5))
    else
      multiplier = 1 * (1 - (fatigue -0.5))
    end
    local divisor = math.random(1, 3)
    local attn_detail = room.staff_member.profile.attention_to_detail / divisor
    local skill = room.staff_member.profile.skill / divisor
    diagnosis_bonus = (attn_detail + 0.4) * skill
  end
  self:modifyDiagnosisProgress(diagnosis_base + (diagnosis_bonus * multiplier))
end

--! Sets the hospital for the patient - additionally removing them from a
-- hospital if they already belong to one. For player hospitals, patients who
-- are not debug or emergency patients are made to seek a reception desk.
--!param hospital (Hospital): hospital to assign to patient
function Patient:setHospital(hospital)
  if self.hospital then
    self.hospital:removePatient(self)
  end
  Humanoid.setHospital(self, hospital)
  if hospital.is_in_world and not self.is_debug and not self.is_emergency then
    self:setNextAction(SeekReceptionAction())
  end
  hospital:addPatient(self)
end

--! Decide the ID of the disease or treatment that the patient is paying for.
--!return (string or nil) Id of the disease or treatment, or nil if the Id could
--! not be decided.
function Patient:getTreatmentDiseaseId()
  if self.diagnosed then
    return self.disease.id
  else
    local room_info = self:getRoom()
    if not room_info then
      print("Warning: Trying to receive money for treated patient who is "..
          "not in a room")
      return nil
    end
    room_info = room_info.room_info
    return "diag_" .. room_info.id
  end
end

--! Estimate the subjective perceived distortion between the price level the
--! patient might expect considering the reputation and the cure effectiveness
--! of a given treatment and the staff internal state.
--!param casebook (table): casebook entry for the treatment.
--!return (float) [-1, 1]. The smaller the value is, the more the patient
--! considers the bill to be under-priced. The bigger the value is, the more
--! the patient patient considers the bill to be over-priced.
function Patient:getPriceDistortion(casebook)
  -- weights
  local happiness_weight = 0.1
  local reputation_weight = 0.6
  local effectiveness_weight = 0.3

  -- map the different variables to [0-1] and merge them
  local reputation = casebook.reputation or self.hospital.reputation
  local effectiveness = casebook.cure_effectiveness

  local weighted_happiness = happiness_weight * self:getAttribute("happiness")
  local weighted_reputation = reputation_weight * (reputation / 1000)
  local weighted_effectiveness = effectiveness_weight * (effectiveness / 100)

  local expected_price_level = weighted_happiness + weighted_reputation + weighted_effectiveness

  -- map to [0-1]
  local price_level = ((casebook.price - 0.5) / 3) * 2

  return price_level - expected_price_level
end

--! Handle attempting to treat this patient
--!
--! If the treatment is effective the patient will be sent home, otherwise they
--! will die. The patient may or may not agree to pay for the treatment
--! depending on whether they consider the price reasonable.
function Patient:treatDisease()
  local hospital = self.hospital

  hospital:receiveMoneyForTreatment(self)

  -- Remove visual effects of disease.
  self.th:setPatientEffect(AnimationEffect.None)

  -- Either the patient is no longer sick, or he/she dies.
  if self:isTreatmentEffective() then
    self:cure()
    self.treatment_history[#self.treatment_history + 1] = _S.dynamic_info.patient.actions.cured
    self:goHome("cured")
  else
    self:die()
  end

  hospital:updatePercentages()
  hospital:paySupplierForDrug(self.disease.id)
  if self.is_emergency then
    hospital:checkEmergencyOver()
  end
end

--! Returns true if patient agrees to pay for the given treatment.
--!param disease_id (string): The id of the disease to test
function Patient:agreesToPay(disease_id)
  local hosp = self.hospital
  local casebook = hosp.disease_casebook[disease_id]
  local price_distortion = self:getPriceDistortion(casebook)
  local is_over_priced = price_distortion > hosp.over_priced_threshold

  if is_over_priced and math.random(1, 5) == 1 then return false end
  self.pay_amount = hosp:getTreatmentPrice(disease_id)

  return true
end

--! Either the patient is cured, or he/she dies.
--!return (boolean) True if cured, false if died.
function Patient:isTreatmentEffective()
  local cure_chance = self.hospital.disease_casebook[self.disease.id].cure_effectiveness
  cure_chance = cure_chance * self.diagnosis_progress

  -- Service quality has a factor on cure chance
  local room = self:getRoom()
  local min_impact = 20
  local service_base = math.max(100 - cure_chance, min_impact)

  local scale = 0.2 -- Quality scaled to +-10%
  local service_factor = (room:getStaffServiceQuality() - 0.5) * scale
  cure_chance = cure_chance + (service_base * service_factor)

  return (cure_chance >= math.random(1,100))
end

--! Change patient internal state to "cured".
function Patient:cure()
  self.cured = true
  self.infected = false
  self.attributes["health"] = 1
end

--! Patient died, process the event.
function Patient:die()
  -- It may happen that this patient was just cured and then the room blew up.
  self.hospital:humanoidDeath(self)
  self:setMood("dead", "activate")

  -- Remove any messages and/or callbacks related to the patient.
  self:unregisterCallbacks()

  self.going_home = true
  if self:getRoom() then
    self:queueAction(MeanderAction():setCount(1))
  else
    self:setNextAction(MeanderAction():setCount(1))
  end
  self:queueAction(DieAction())
  self:setDynamicInfoText(_S.dynamic_info.patient.actions.dying)
end

-- Actions we can interrupt when at a fully empty tile.
local good_actions = {walk=true, idle=true, seek_room=true, queue=true}

--! Test whether the current tile of the patient is useful for inserting an
-- action that needs a fully empty tile in the hospital.
--!param cur_action Current action of the patient.
--!return Whether the tile can be used for inserting an action.
function Patient:atFullyEmptyTile(cur_action)
  if not good_actions[cur_action.name] then return false end
  if self.going_home then return false end

  local th = self.world.map.th
  local cell_flags = th:getCellFlags(self.tile_x, self.tile_y)
  if not cell_flags.buildable or not cell_flags.hospital then return false end

  local parcel = cell_flags.parcelId
  return parcel ~= 0 and th:getPlotOwner(parcel) == self.hospital:getPlayerIndex()
end

--! Falling animations for when there is an earth quake or the player is being very mean
--!param player_init (bool) if true, player triggered the fall
function Patient:falling(player_init)
  local current = self:getCurrentAction()
  current.keep_reserved = true
  if self.falling_anim and self:atFullyEmptyTile(current) and self.has_fallen == 1 then
    self.has_fallen = 2
    self:queueAction(FallingAction(), 1)
    self:queueAction(OnGroundAction(), 2)
    self:queueAction(GetUpAction(), 3)
    -- show the patient is annoyed, if possible
    if math.random(1, 5) == 3 and self.shake_fist_anim then
      self:queueAction(ShakeFistAction(), 4)
      self:interruptAndRequeueAction(current, 5)
    else
      self:interruptAndRequeueAction(current, 4)
    end
    if player_init then self:fallingAnnounce() end
    self:changeAttribute("happiness", -0.05) -- falling makes you very unhappy
  end
end

function Patient:fallingAnnounce()
  local msg = {
  (_A.warnings.falling_1),
  (_A.warnings.falling_2),
  (_A.warnings.falling_3),
  (_A.warnings.falling_4),
  (_A.warnings.falling_5),
  (_A.warnings.falling_6),
  }
  self.hospital:giveAdvice(msg)
end

function Patient:vomit()
  local current = self:getCurrentAction()
  --Only vomit under these conditions. Maybe I should add a vomit for patients in queues too?
  if self:atFullyEmptyTile(current) and self.has_vomitted == 0 then
    self:queueAction(VomitAction(), 1)
    self:interruptAndRequeueAction(current, 2)
    self.has_vomitted = self.has_vomitted + 1
    self:changeAttribute("happiness", -0.02) -- being sick makes you unhappy
  else
    return
  end
end

function Patient:pee()
  local current = self:getCurrentAction()
  --Only pee under these conditions. As with vomit, should they also pee if in a queue?
  if self:atFullyEmptyTile(current) then
    self:queueAction(PeeAction(), 1)
    self:interruptAndRequeueAction(current, 2)
    self:setMood("poo", "deactivate")
    self:changeAttribute("happiness", -0.02) -- not being able to find a loo and doing it in the corridor will make you sad too
    if not self.hospital.did_it_on_floor then
      self.hospital.did_it_on_floor = true
      self.hospital:giveAdvice({_A.warnings.people_did_it_on_the_floor})
    end
  else
    return
  end
end

function Patient:checkWatch()
  local action = self:getCurrentAction()
  if self.check_watch_anim and (action.name == "idle" or action.name == "seek_room") and not action.is_leaving then
    self:queueAction(CheckWatchAction(), 0)
  end
end

function Patient:yawn()
  local action = self:getCurrentAction()
  if self.yawn_anim and (action.name == "idle" or action.name == "seek_room") and not action.is_leaving then
    self:queueAction(YawnAction(), 0)
  end
end

function Patient:tapFoot()
  local action = self:getCurrentAction()
  if self.tap_foot_anim and (action.name == "idle" or action.name == "seek_room") and not action.is_leaving then
    self:queueAction(TapFootAction(), 0)
  end
end

--! Make the patient leave the hospital. This function also handles some
--! statistics (number of cured/kicked out patients, etc.)
--! The mood icon is updated accordingly. Reputation is impacted accordingly.
--!param reason (string): the reason why the patient is sent home, which could be:
--! -"cured": When the patient is cured.
--! -"kicked": When the patient is kicked anyway, either manually,
--! either when no treatment can be found for her/him, etc.
--! -"over_priced": When the patient decided to leave because he/she believes
--! the last treatment is over-priced.
--param disease_id (string): When the reason is "over_priced" this is the
--! id of the disease/diagnosis that the patient considered over_priced
function Patient:goHome(reason, disease_id)
  local hosp = self.hospital
  if self.going_home then
    -- The patient should be going home already! Anything related to the hospital
    -- will not be updated correctly, but we still want to try to get the patient to go home.
    TheApp.world:gameLog("Warning: goHome called when the patient is already going home")
    self:despawn()
    return
  end
  if reason == "cured" then
    self:setMood("cured", "activate")
    self:changeAttribute("happiness", 0.8)
    hosp:updateCuredCounts(self)
    self:setDynamicInfoText(_S.dynamic_info.patient.actions.cured)

  elseif reason == "kicked" then
    self:setMood("exit", "activate")
    hosp:updateNotCuredCounts(self, reason)

  elseif reason == "over_priced" then
    self:setMood("sad_money", "activate")
    self:changeAttribute("happiness", -0.5)

    local treatment_name = self.hospital.disease_casebook[disease_id].disease.name
    self.hospital:giveAdvice({_A.warnings.patient_not_paying:format(treatment_name)})
    hosp:updateNotCuredCounts(self, reason)
    self:clearDynamicInfo()
    self:setDynamicInfo('text', {"", _S.dynamic_info.patient.actions.prices_too_high})

  elseif reason == "evacuated" then
    self:clearDynamicInfo()
    self:setDynamicInfo('text', {"", _S.dynamic_info.patient.actions.epidemic_sent_home})
    self:setMood("exit","activate")

  else
    TheApp.world:gameLog("Error: unknown reason " .. reason .. "!")
  end

  hosp:updatePercentages()

  -- Debug patients must be removed from the debug list so they can despawn properly
  if self.is_debug then
    hosp:removeDebugPatient(self)
  end

  -- Remove any messages and/or callbacks related to the patient.
  self:unregisterCallbacks()

  self.going_home = true
  self.waiting = nil

  -- Remove any vaccination calls from patient
  if not self.vaccinated then
    self.world.dispatcher:dropFromQueue(self)
  end

  -- allow timer to end early and after going_home is set
  if self.is_emergency then
    hosp:checkEmergencyOver()
  end

  local room = self:getRoom()
  if room then
    room:makeHumanoidLeave(self)
  end
  Humanoid.despawn(self)
end

-- Despawns the patient and removes them from the hospital
function Patient:despawn()
  self.hospital:removePatient(self)
  Humanoid.despawn(self)
end

-- Checks if the room the patient is in is the final treatment room for their disease
-- NB: Check diagnosed status as some illnesses use Psych for diagnosis and treatment
function Patient:_checkIfCureRoom(room)
  local num_rooms = #self.disease.treatment_rooms
  return (room and self.disease.treatment_rooms[num_rooms] == room.room_info.id
      and self.diagnosed)
end

-- This function handles changing of the different attributes of the patient.
-- For example if thirst gets over a certain level (now: 0.7), the patient
-- tries to find a drinks machine nearby.
function Patient:tickDay()
  -- First of all it may happen that this patient is tired of waiting and goes home.
  if self.waiting then
    self.waiting = self.waiting - 1
    if self.waiting == 0 then
      self:goHome("kicked")
      if self.diagnosed then
        -- No treatment rooms
        self:setDynamicInfoText(_S.dynamic_info.patient.actions.no_treatment_available)
      else
        -- No diagnosis rooms
        self:setDynamicInfoText(_S.dynamic_info.patient.actions.no_diagnoses_available)
      end
    elseif self.waiting == 10 then
      self:tapFoot()
    elseif self.waiting == 20 then
      self:yawn()
    elseif self.waiting == 30 then
      self:checkWatch()
    end

    if self.has_vomitted and self.has_vomitted > 0 then
      self.has_vomitted = 0
    end
  end

  -- if patients are getting unhappy, then maybe we should see this!
  if self:getAttribute("happiness") < 0.3 then
    self:setMood("sad2", "activate")
  else
    self:setMood("sad2", "deactivate")
  end
  -- Now call the parent function - it checks
  -- if we're outside the hospital or on our way home.
  if not Humanoid.tickDay(self) then
    return
  end

  -- Die before we poo or drink
  -- Patient has been in the hospital for over 6 months and is still not well, so
  -- will become sad and will either get fed up and leave or stay in the hope that you
  -- will cure them before they die.
  -- Note: This behaviour intentionally differs from Theme Hospital where being close to
  -- death does not impact happiness.
  -- TODO clean up this block, nonmagical numbers
  local health = self:getAttribute("health")
  if health >= 0.18 and health < 0.22 then
    self:setMood("dying1", "activate")
    self:changeAttribute("happiness", -0.0002) -- waiting too long will make you sad
    -- There is a 1/3 chance that the patient will get fed up and leave.
    -- This is potentially run 10 ((0.22-0.18)/0.004) times, hence the 1/30 chance.
    -- If patient is already in the cure room, let the treatment happen.
    if not self:_checkIfCureRoom(self:getRoom()) and math.random(1,30) == 1 then
      self:setDynamicInfoText(_S.dynamic_info.patient.actions.fed_up)
      self:setMood("dying1", "deactivate")
      self:goHome("kicked")
    end
  elseif health >= 0.14 and health < 0.18 then
    self:setMood("dying1", "deactivate")
    self:setMood("dying2", "activate")
  -- now wishes they had gone to that other hospital
  elseif health >= 0.10 and health < 0.14 then
    self:setMood("dying2", "deactivate")
    self:setMood("dying3", "activate")
  -- starts to take a turn for the worse and is slipping away
  elseif health >= 0.06 and health < 0.10 then
    self:setMood("dying3", "deactivate")
    self:setMood("dying4", "activate")
  -- fading fast
  elseif health >= 0.01 and health < 0.06 then
    self:setMood("dying4", "deactivate")
    self:setMood("dying5", "activate")
  -- it's not looking good
  elseif health > 0.00 and health < 0.01 then
    self.attributes["health"] = 0.0
  -- is there time to say a prayer
  elseif health == 0.0 then
    if not self:getRoom() and not self:getCurrentAction().is_leaving then
      self:setMood("dying5", "deactivate")
      self:die()
    end
    -- Patient died, will die when they leave the room, will be cured, or is leaving
    -- the hospital. Regardless we do not need to adjust any other attribute
    return
  end

  -- Note: to avoid empty action queue error if the player spam clicks a patient at the same time as the day changes
  -- there is now an between "neutral" stage.
  if self.has_fallen == 3 then
    self.has_fallen = 1
  elseif self.has_fallen == 2 then
    self.has_fallen = 3
  end

  -- Update health history.
  if not self.health_history then
    -- First day, initialize health history.
    self.health_history = {}
    self.health_history[1] = self:getAttribute("health")
    self.health_history["last"] = 1
    self.health_history["size"] = 20
  else
    -- Update the health history, wrapping around the array.
    local last = self.health_history["last"] + 1
    if last > self.health_history["size"] then last = 1 end
    self.health_history[last] = self:getAttribute("health")
    self.health_history["last"] = last
  end

  -- Vomitings.
  if self.vomit_anim and not self:getRoom() and not self:getCurrentAction().is_leaving and not self:getCurrentAction().is_entering then
    --Nausea level is based on health then proximity to vomit is used as a multiplier.
    --Only a patient with a health value of less than 0.8 can be the initial vomiter, however :)
    local initialVomitMult = 0.002 --The initial chance of vomiting.
    local proximityVomitMult = 1.5 --The multiplier used when in proximity to vomit.
    local nausea = (1.0 - self:getAttribute("health")) * initialVomitMult
    local foundVomit = {}
    local numVomit = 0

    self.world:findObjectNear(self, "litter", 2, function(x, y)
      local litter = self.world:getObject(x, y, "litter")
    if not litter then
    return
    end
      if litter:vomitInducing() then
        local alreadyFound = false
        for i=1,numVomit do
          if foundVomit[i] == litter then
            alreadyFound = true
            break
          end
        end

        if not alreadyFound then
          numVomit = numVomit + 1
          foundVomit[numVomit] = litter
        end
      end
      -- seeing litter will make you unhappy. If it is pee or puke it is worse
      if litter:anyLitter() then
        self:changeAttribute("happiness", -0.0002)
      else
        self:changeAttribute("happiness", -0.0004)
      end
    end) -- End of findObjectNear
    -- As we don't yet have rats, ratholes and dead rats the chances of vomitting are slim
    -- as a temp fix for this I have added 0.5 to the < nausea equation,
    -- this may want adjusting or removing when the other factors are in the game MarkL
    if self:getAttribute("health") <= 0.8 or numVomit > 0 or self:getAttribute("happiness") < 0.6 then
      nausea = nausea * ((numVomit+1) * proximityVomitMult)
      if math.random() < nausea + 0.5 then
        self:vomit()
      end
    end
  end

  -- It is nice to see plants, but dead plants make you unhappy
  self.world:findObjectNear(self, "plant", 2, function(x, y)
    local plant = self.world:getObject(x, y, "plant")
    if plant then
      self:changeAttribute("happiness", -0.0003 + (plant:isPleasingFactor() * 0.0001))
    end
  end)
  -- It always makes you happy to see you are in safe place
  self.world:findObjectNear(self, "extinguisher", 2, function()
    self:changeAttribute("happiness", 0.0002)
  end)
  -- sitting makes you happy whilst standing and walking does not
  if self:goingToUseObject("bench") then
    self:changeAttribute("happiness", 0.00002)
  else
    self:changeAttribute("happiness", -0.00002)
  end

  -- Each tick both thirst, warmth and toilet_need changes and health decreases.
  self:changeAttribute("thirst", self:getAttribute("warmth") * 0.02 + 0.004 * math.random() + 0.004)
  self:changeAttribute("health", - 0.004)
  if self.disease.more_loo_use then
    self:changeAttribute("toilet_need", 0.018 * math.random() + 0.008)
  else
    self:changeAttribute("toilet_need", 0.006 * math.random() + 0.002)
  end
  -- Maybe it's time to visit the loo?
  if self:getAttribute("toilet_need") > 0.75 then
    if self.pee_anim and not self:getCurrentAction().is_leaving and
        not self:getCurrentAction().is_entering and not self.in_room then
      if math.random(1, 10) < 5 then
        self:pee()
        self:changeAttribute("toilet_need", -(0.5 + math.random()*0.15))
        self.going_to_toilet = "no"
      else
        -- If waiting for user response, do not send to toilets, as this messes
        -- things up.
        if self.going_to_toilet == "no" and not self.waiting then
          self:setMood("poo", "activate")
          -- Check if any room exists.
          if not self.world:findRoomNear(self, "toilets") then
            self.going_to_toilet = "no-toilets" -- Gets reset when a new toilet is built (then, patient will try again).
          -- Otherwise we can queue the action, but only if not in any rooms right now.
          elseif not self:getRoom() and not self:getCurrentAction().is_leaving and not self:getCurrentAction().pee then
            self:setNextAction(SeekToiletsAction():setMustHappen(true))
            self.going_to_toilet = "yes"
          end
        end
      end
    end
  end
  if self.disease.yawn and math.random(1, 10) == 5 then
    self:yawn()
  end

  -- If thirsty enough a soda would be nice
  if self:getAttribute("thirst") > 0.7 then
    self:changeAttribute("happiness", -0.002)
    self:setMood("thirsty", "activate")
    -- If there's already an action to buy a drink in the action queue, or
    -- if we're going to the loo, do nothing
    if self:goingToUseObject("drinks_machine") or self.going_to_toilet ~= "no" then
      return
    end
    -- Don't check for a drinks machine too often
    if self.timeout and self.timeout > 0 then
      self.timeout = self.timeout - 1
      return
    end
    -- The only allowed situations to grab a soda is when queueing
    -- or idling/walking in the corridors
    -- Also make sure the walk action when leaving a room has a chance to finish.
    if not self:getRoom() and not self:getCurrentAction().is_leaving and not self.going_home then
      local machine, lx, ly = self.world:
          findObjectNear(self, "drinks_machine", 8)

      -- If no machine can be found, resume previous action and wait a
      -- while before trying again. To get a little randomness into the picture
      -- it's not certain we go for it right now.
      if not machine or not lx or not ly or math.random(1,10) < 3 then
        self.timeout = math.random(2,4)
        return
      end

      -- Callback function when the machine has been used
      local --[[persistable:patient_drinks_machine_after_use]] function after_use()
        self:changeAttribute("thirst", -(0.7 + math.random()*0.3))
        self:changeAttribute("toilet_need", 0.05 + math.random()*0.05)
        self:setMood("thirsty", "deactivate")
        -- The patient might be kicked while buying a drink
        if not self.going_home then
          self.hospital:sellSodaToPatient(self)
        end
        -- The patient might also throw the can on the floor, bad patient!
        if math.random() < 0.6 then
          -- It will be dropped between 1 and 12 tiles away (litter bin catches 8 radius).
          self.litter_countdown = math.random(1, 12)
        end
      end

      -- If we are queueing, let the queue handle the situation.
      for _, current_action in ipairs(self.action_queue) do
        if current_action.name == "queue" then
          local callbacks = current_action.queue.callbacks[self]
          if callbacks then
            callbacks:onGetSoda(self, machine, lx, ly, after_use)
            return
          end
        end
      end

      -- Or, if walking or idling insert the needed actions in
      -- the beginning of the queue
      local current = self:getCurrentAction()
      if current.name == "walk" or current.name == "idle" or current.name == "seek_room" then
        -- Go to the machine, use it, and then continue with
        -- whatever he/she was doing.
        current.keep_reserved = true
        self:queueAction(WalkAction(lx, ly):setMustHappen(true):disableTruncate(), 1)
        self:queueAction(UseObjectAction(machine):setAfterUse(after_use):setMustHappen(true), 2)
        machine:addReservedUser(self)
        -- Insert the old action again, a little differently depending on
        -- what the previous action was.
        self:interruptAndRequeueAction(current, 3, true)
      end
    end
  end

  -- If the patient is sitting on a bench or standing and queued,
  -- it may be a situation where he/she is not in the queue
  -- anymore, but should be. If this is the case for more than
  -- 2 ticks, go to reception
  if #self.action_queue > 1 and (self:getCurrentAction().name == "use_object" or
      self:getCurrentAction().name == "idle") and
      self.action_queue[2].name == "queue" then
    local found = false
    for _, humanoid in ipairs(self.action_queue[2].queue) do
      if humanoid == self then
        found = true
        break
      end
    end

    if not found then
      if not self.noqueue_ticks then
        self.noqueue_ticks = 1
      elseif self.noqueue_ticks > 2 then
        self.world:gameLog("A patient has a queue action, but is not in the corresponding queue")
        self:setNextAction(SeekReceptionAction())
      else
        self.noqueue_ticks = self.noqueue_ticks + 1
      end
    else
      self.noqueue_ticks = 0
    end
  end
end

function Patient:notifyNewRoom(room)
  Humanoid.notifyNewRoom(self, room)
  if self.going_to_toilet == "no-toilets" and room.room_info.id == "toilets" then
    self.going_to_toilet = "no" -- Patient can try again going to the loo.
  end
end

-- Called each time the patient moves to a new tile.
function Patient:setTile(x, y)
  if not self.litter_countdown then
    -- If arrived at the first tile of the hospital, give patient some litter.
    if x and self.world.map.th:getCellFlags(x, y).buildable then
      -- Small hospitals are around 40-50 tiles.
      self.litter_countdown = math.random(20, 100)
    end

  elseif self.hospital and not self.going_home then
    self.litter_countdown = self.litter_countdown - 1

    -- Is the patient about to drop some litter?
    if self.litter_countdown == 0 then
      if x and not self:getRoom() and not self.world:getObjects(x, y) and
          self.world.map.th:getCellFlags(x, y).buildable and
          self.hospital:isInHospital(x, y) and
          (not self.world:findObjectNear(self, "bin", 8) or math.random() < 0.05) then
        -- Drop some litter!
        local trash = math.random(1, 4)
        local litter = self.world:newObject("litter", x, y)
        litter:setLitterType(trash, math.random(0, 1))
        if not self.hospital.hospital_littered then
          self.hospital.hospital_littered = true

          -- A callout is only needed if there are no handymen employed
          if self.hospital:countStaffOfCategory("Handyman", 1) == 0 then
            self.hospital:giveAdvice({_A.staff_advice.need_handyman_litter})
          end
        end
      end

      -- Always give new litter to drop.
      self.litter_countdown = math.random(30, 150)
    end
  end

  Humanoid.setTile(self, x, y)
end

-- As of now each time a bench is placed the world notifies all patients
-- in the vicinity through this function.
function Patient:notifyNewObject(id)
  -- If currently queueing it would be nice to be able to sit down.
  assert(id == "bench", "Can only handle benches at the moment")
  -- Look for a queue action and tell this patient to look for a bench
  -- if currently standing up.
  for _, action in ipairs(self.action_queue) do
    if action.name == "queue" then
      local callbacks = action.queue.callbacks[self]
      if callbacks then
        assert(action.done_init, "Queue action was not yet initialized")
        if action:isStanding() then
          callbacks:onChangeQueuePosition(self)
          break
        end
      end
    end
  end
end

function Patient:addToTreatmentHistory(room)
  local should_add = true
  -- Do not add facility rooms such as toilets to the treatment history.
  for i, _ in pairs(room.categories) do
    if i == "facilities" then
      should_add = false
      break
    end
  end
  if should_add then
    self.treatment_history[#self.treatment_history + 1] = room.name
  end
end

--! Sets the dynamic text currently in use by the patient
--!param action_string (string) What text to say in dynamic text
function Patient:setDynamicInfoText(action_string)
  self.action_string = action_string
  self:updateDynamicInfo()
end

--! Updates a patient's dynamic info
--! Can be called direct to refresh only
function Patient:updateDynamicInfo()
  local action_string = self.action_string or ""
  local info = ""
  if self.going_home then
    self:setDynamicInfo('progress', nil)
  elseif self.diagnosed then
    if self.diagnosis_progress < 1.0 then
      -- The cure was guessed
      info = _S.dynamic_info.patient.guessed_diagnosis:format(self.disease.name)
    else
      if self.is_emergency then
        info = _S.dynamic_info.patient.emergency:format(self.disease.name)
      else
        info = _S.dynamic_info.patient.diagnosed:format(self.disease.name)
      end
    end
    self:setDynamicInfo('progress', nil)
  else
    info = _S.dynamic_info.patient.diagnosis_progress
    -- TODO: If the policy is changed this info will not be changed until the next
    -- diagnosis facility has been visited.
    local divider = 1
    if self.hospital then
      divider = self.hospital.policies["stop_procedure"]
    end
    if self.diagnosis_progress then
      self:setDynamicInfo('progress', math.min(1.0, self.diagnosis_progress / divider))
    end
  end
  -- Set the centre line of dynamic info based on contagiousness, if appropriate
  local epidemic = self.hospital and self.hospital.epidemic
  if epidemic and self.infected and epidemic.coverup_selected then
    if self.vaccinated then
      self:setDynamicInfo('text',
        {action_string, _S.dynamic_info.patient.actions.epidemic_vaccinated, info})
    else
      self:setDynamicInfo('text',
        {action_string, _S.dynamic_info.patient.actions.epidemic_contagious, info})
    end
  else
    self:setDynamicInfo('text', {action_string, "", info})
  end
end

--[[ Update availability of a choice in message owned by this patient, if any
!param choice (string) The choice that needs updating (currently "research" or "guess_cure").
]]
function Patient:updateMessage(choice)
  if self.message and self.message.choices then
    local message_choice
    local enabled = false

    for _, c in ipairs(self.message.choices) do
      if c.choice == choice then
        message_choice = choice
      end
    end

    if choice == "research" and message_choice == choice then
      -- enable only if research department is built and a room in the treatment chain is undiscovered
      local req = self.hospital:checkDiseaseRequirements(self.disease.id)
      if req then
        enabled = (self.hospital:countRoomOfType("research", 1) > 0 and
                   self.hospital:countStaffOfCategory("Researcher", 1) > 0)

        local strings = _S.fax.disease_discovered_patient_choice
        local output_text = strings.can_not_cure
        if #req.rooms == 1 then
          local room_name, required_staff, staff_name = self.world:getRoomNameAndRequiredStaffName(req.rooms[1])
          if req.staff[required_staff] or 0 > 0 then
            output_text = strings.need_to_build_and_employ:format(room_name, staff_name)
          else
            output_text = strings.need_to_build:format(room_name)
          end
        elseif #req.rooms == 0 and next(req.staff) then
          output_text = strings.need_to_employ:format(StaffProfile.translateStaffClass(next(req.staff)))
        end
        self.message[3].text = output_text
      else
        -- no requirements missing
        enabled = false
      end
    -- TODO: implement choice == "guess_cure"
    end

    for _, c in ipairs(self.message.choices) do
      if c.choice == choice then
        c.enabled = enabled
      end
    end

    -- Update the fax window if it is open.
    local window = self.world.ui:getWindow(UIFax)
    if window then
      window:updateChoices()
    end

  end
end

--[[ Show patient infected status ]]
function Patient:setInfectedStatus()
  self:removeAnyEpidemicStatus()
  self:setMood("epidemy4","activate")
  self.vaccination_candidate = false
end

--[[ Show patient as ready for vaccination status ]]
function Patient:setToReadyForVaccinationStatus()
  self:removeAnyEpidemicStatus()
  self:setMood("epidemy2","activate")
  self.marked_for_vaccination = true
end

--[[ Show patient selected vaccination candidate status ]]
function Patient:giveVaccinationCandidateStatus()
  self:removeAnyEpidemicStatus()
  self:setMood("epidemy3","activate")
  self.vaccination_candidate = true
end

--[[ Remove the vaccination candidate icon and status from the patient ]]
function Patient:removeVaccinationCandidateStatus()
  if not self.vaccinated then
    self:removeAnyEpidemicStatus()
    self:setMood("epidemy2","activate")
    self.vaccination_candidate = false
  end
end

--[[ Show vaccinated status for vaccinated patient ]]
function Patient:setVaccinatedStatus()
  self:removeAnyEpidemicStatus()
  self:setMood("epidemy1","activate")
  self.marked_for_vaccination = false
  self.vaccinated = true
end

--[[ Clear all epidemic status ]]
function Patient:removeAnyEpidemicStatus()
  self:setMood("epidemy1","deactivate") -- vaccinated (step 4)
  self:setMood("epidemy2","deactivate") -- marked (step 2)
  self:setMood("epidemy3","deactivate") -- choosed by nurse (step 3)
  self:setMood("epidemy4","deactivate") -- infected (step 1)
end

function Patient:afterLoad(old, new)
  if old < 68 then
    if self.going_home then
      self.waiting = nil
    end
  end
  if old < 87 then
    if self.die_anims == nil then
      self.die_anims = {}
    end

    -- New humanoid animation: rise_hell_east:
    if self:isMalePatient() then
      if self.humanoid_class ~= "Alternate Male Patient" then
        self.die_anims.rise_hell_east = 384
      else
        self.die_anims.rise_hell_east = 3404
      end
    else
      self.die_anims.rise_hell_east = 580
    end
  end
  if old < 108 then
    if self.going_to_toilet then
      -- Not easily decidable what the patient is doing here,
      -- removing a toilet while it's used is unlikely to happen.
      if self.world:findRoomNear(self, "toilets") then
        self.going_to_toilet = "yes"
      else
        self.going_to_toilet = "no-toilets"
      end
    else
      self.going_to_toilet = "no"
    end
  end
  if old < 158 then
    -- Always overwrite patient effect from old saves since it is
    -- loaded from a dummy field which used to have another meaning.
    if self.disease and not self.cured then
      self.th:setPatientEffect(self.disease.effect or AnimationEffect.None)
    else
      self.th:setPatientEffect(AnimationEffect.None)
    end
  end
  -- fix walks into room - regression in #2086
  if old < 177 then
    for i, action in ipairs(self.action_queue) do
      if action.name == "walk" and action.is_entering then
        action.saved_must_happen = false
        -- if its not the currently executing action
        -- we should set must_happen to false
        if i > 1 then
          action.must_happen = false
        end
      end
    end
  end
  if old < 190 then
    if self.humanoid_class == "Standard Female Patient" then
      self.on_ground_anim = 1764
    end
  end
  if old < 211 then
    self.under_infection_attempt = self.attempted_to_infect
    self.attempted_to_infect = nil
  end

  if old < 213 then
    self.mood_marker = 1
  end

  self:updateDynamicInfo()
  Humanoid.afterLoad(self, old, new)
end

function Patient:isMalePatient()
  if string.find(self.humanoid_class, "Female") then return false
  elseif string.find(self.humanoid_class, "Male") then return true
  else
    local male_patient_classes = {
      ["Chewbacca Patient"] = true,
      ["Elvis Patient"] = true,
      ["Invisible Patient"] = true
    }
    return male_patient_classes[self.humanoid_class] ~= nil
  end
end

--[[ Interrupt a patients current action and resumes it after
!param current_action (string) Action being interrupted
!param queue_pos (int) Position to insert resumed action in queue
!param meander_before_resume (bool) Indicator to insert an additional action before resuming.
]]
function Patient:interruptAndRequeueAction(current_action, queue_pos, meander_before_resume)
  -- Rebuild the current action.
  local requeue_action
  if current_action.name == "idle" then
    requeue_action = IdleAction():setMustHappen(current_action.must_happen)
    requeue_action:setDirection(current_action.direction)

    -- Go away a little before continuing with that important action.
    if meander_before_resume then
      self:queueAction(MeanderAction():setCount(1), queue_pos)
    end
  elseif current_action.name == "walk" then
    requeue_action = WalkAction(current_action.x, current_action.y)
    requeue_action:setMustHappen(current_action.must_happen)
    if current_action.saved_must_happen ~= nil then
      requeue_action.must_happen = current_action.saved_must_happen
    end
    -- need to copy the reserve_on_resume, otherwise the new queued action will not
    -- unreserve on interrupt
    requeue_action.reserve_on_resume = current_action.reserve_on_resume
    requeue_action:setIsEntering(current_action.is_entering)
  else
    -- We were seeking a room, start that action from the beginning
    -- i.e. do not set the must_happen flag.
    requeue_action = SeekRoomAction(current_action.room_type)
    if current_action.treatment_room then requeue_action:enableTreatmentRoom() end
    if current_action.diagnosis_room then
      requeue_action:setDiagnosisRoom(current_action.diagnosis_room)
    end
    requeue_action.message_sent = true
  end
  self:queueAction(requeue_action, queue_pos)

  -- now interrupt
  if current_action.on_interrupt then
    current_action.on_interrupt(current_action, self)
  else
    self:finishAction()
  end
end

-- Dummy callback for savegame compatibility
local callbackNewRoom = --[[persistable:patient_toilet_build_callback]] function() end
