-- Run from Gen3Mod/gen1recomp-0.3.73 with luajit.
package.path = './?.lua;./?/init.lua;' .. package.path
local T = require('tests.modkit')
local SL = dofile('../coop/g3_coop/lib/soullink.lua')
local Tracker = dofile('../coop/g3_coop/lib/tracker.lua')
local function area(sp, a) return SL.hoennStarterArea('emerald', sp, a) end
for _, version in ipairs({'emerald','ruby','sapphire'}) do
  for _, species in ipairs({277,280,283}) do
    T.eq(SL.hoennStarterArea(version,species,16),0,version .. ' starter belongs to Littleroot')
  end
end
T.eq(SL.hoennStarterArea('firered',277,16),16,'Kanto areas unchanged')
T.eq(area(290,16),16,'other Route 101 gifts unchanged')
T.eq(area(277,17),17,'starter-species gift elsewhere unchanged')
local run = SL.newRun({tid='A',nm='A'},SL.DEFAULT_RULES,'old-run')
run.partner = {tid='B',nm='B'}
run.logs.A = {{k='enc',a=16,s=283,h='gift'}, {k='catch',a=16,s=283,u='1:1'},
  {k='nick',u='1:1',nm='MUDDY'}}
run.logs.B = {{k='enc',a=16,s=277,h='gift'}, {k='catch',a=16,s=277,u='2:2'},
  {k='faint',a=17,u='2:2',by='CALVIN'}}
local v = SL.derive(run,nil,area)
T.eq(v.mine.areas[0].u,'1:1','old local starter moves to town')
T.eq(v.theirs.areas[0].u,'2:2','old partner starter moves to town')
T.eq(v.mine.areas[16],nil,'Route 101 is free')
T.eq(v.pairs[1].status,'dead','the existing linked death is preserved')
T.eq(v.names['1:1'],'MUDDY','nickname preserved')
T.eq(v.theirs.faintList[1].a,17,'actual faint location preserved')
T.eq(run.logs.A[1].a,16,'wire history is not rewritten')
T.eq(SL.judge(run,run.rules,v,{a=16,s=290,h='wild'}),'counts','Route 101 wild encounter now counts')
run.logs.A[4] = {k='enc',a=16,s=290,h='wild'}
run.logs.A[5] = {k='catch',a=16,s=290,u='3:1'}
v = SL.derive(run,nil,area)
T.eq(v.mine.areas[16].u,'3:1','later Route 101 catch stays on the route')
T.eq(v.mine.areas[0].u,'1:1','starter stays in town after a route catch')
SL.mergeLog(run,'B',1,{{k='enc',a=16,s=277,h='gift'}, {k='catch',a=16,s=277,u='2:2'}})
T.eq(SL.derive(run,nil,area).theirs.areas[0].u,'2:2','old peer history still normalizes after resync')

local s = {trainerId=1,name='A',party={}}
local saved
local tr = Tracker.new({SL=SL,now=function() return 0 end,toast=function() end,
  session=function() return s end,options=function() return {on=true,gift=true} end,
  read=function() return nil,'not_found' end,write=function(_,r) saved=r;return true end,
  newId=function() return 'new' end,areaOf=function() return 16 end,giftArea=area,
  areaName=tostring,speciesName=tostring,isShiny=function() return false end,isEgg=function() return false end})
tr:ensure()
tr:_gift({species=280,personality=4,otId=1})
T.eq(saved.logs[tr.tid][1].a,0,'new starter gift is recorded in town')
T.eq(tr:view().mine.areas[16],nil,'new starter leaves Route 101 available')
T.finish('g3_coop starter encounter area')
