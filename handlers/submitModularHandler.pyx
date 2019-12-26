import base64
import collections
import json
import sys
import threading
import traceback
from urllib.parse import urlencode
import math

import requests
import tornado.gen
import tornado.web

import secret.achievements.utils
from common.constants import gameModes
from common.constants import mods
from common.log import logUtils as log
from common.ripple import userUtils
from common.web import requestsManager
from constants import exceptions
from constants import rankedStatuses
from constants.exceptions import ppCalcException
from helpers import aeshelper
from helpers import replayHelper
from helpers import leaderboardHelper
from helpers import leaderboardHelperRelax
from helpers import leaderboardHelperAuto
from helpers.generalHelper import zingonify
from objects import beatmap
from objects import glob
from objects import score
from objects import scoreboard
from objects import scoreRelax
from objects import scoreboardRelax
from objects import scoreboardAuto
from objects import scoreboardRelaxScore
from objects import scoreboardAutoScore
from objects import scoreAuto
from objects.charts import BeatmapChart, OverallChart
from secret import butterCake

MODULE_NAME = "submit_modular"
class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /web/osu-submit-modular.php
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	#@sentry.captureTornado
	def asyncPost(self):
		newCharts = self.request.uri == "/web/osu-submit-modular-selector.php"
		try:
			# Resend the score in case of unhandled exceptions
			keepSending = True

			# Get request ip
			ip = self.getRequestIP()

			# Print arguments
			if glob.debug:
				requestsManager.printArguments(self)

			# Check arguments
			if not requestsManager.checkArguments(self.request.arguments, ["score", "iv", "pass"]):
				raise exceptions.invalidArgumentsException(MODULE_NAME)

			# TODO: Maintenance check

			# Get parameters and IP
			scoreDataEnc = self.get_argument("score")
			iv = self.get_argument("iv")
			password = self.get_argument("pass")
			ip = self.getRequestIP()

			# Get bmk and bml (notepad hack check)
			if "bmk" in self.request.arguments and "bml" in self.request.arguments:
				bmk = self.get_argument("bmk")
				bml = self.get_argument("bml")
			else:
				bmk = None
				bml = None

			# Get right AES Key
			if "osuver" in self.request.arguments:
				aeskey = "osu!-scoreburgr---------{}".format(self.get_argument("osuver"))
			else:
				aeskey = "h89f2-890h2h89b34g-h80g134n90133"

			# Get score data
			log.debug("Decrypting score data...")
			scoreData = aeshelper.decryptRinjdael(aeskey, iv, scoreDataEnc, True).split(":")
			username = scoreData[1].strip()

			# Login and ban check
			userID = userUtils.getID(username)
			# User exists check
			if userID == 0:
				raise exceptions.loginFailedException(MODULE_NAME, userID)
			# Bancho session/username-pass combo check
			if not userUtils.checkLogin(userID, password, ip):
				raise exceptions.loginFailedException(MODULE_NAME, username)
			# 2FA Check
			if userUtils.check2FA(userID, ip):
				raise exceptions.need2FAException(MODULE_NAME, userID, ip)
			# Generic bancho session check
			#if not userUtils.checkBanchoSession(userID):
				# TODO: Ban (see except exceptions.noBanchoSessionException block)
			#	raise exceptions.noBanchoSessionException(MODULE_NAME, username, ip)
			# Ban check
			if userUtils.isBanned(userID):
				raise exceptions.userBannedException(MODULE_NAME, username)
			# Data length check
			if len(scoreData) < 16:
				raise exceptions.invalidArgumentsException(MODULE_NAME)

			# Get restricted
			restricted = userUtils.isRestricted(userID)

			# Get variables for relax
			used_mods = int(scoreData[13])
			UsingRelax = used_mods & 128
			UsingAuto = used_mods & 8192

			# Create score object and set its data
			log.info("{} has submitted a score on {}...".format(username, scoreData[0]))
			if UsingRelax:
				s = scoreRelax.score()
			elif UsingAuto:
				s = scoreAuto.score()
			else:
				s = score.score()
			s.setDataFromScoreData(scoreData)
			s.playerUserID = userID
			if s.completed == -1:
				log.warning("We got a dulicated score.")
				return

			
			s.playerUserID = userID

			
			beatmapInfo = beatmap.beatmap()
			beatmapInfo.setDataFromDB(s.fileMd5)
			
			if beatmapInfo.rankedStatus == rankedStatuses.NOT_SUBMITTED or beatmapInfo.rankedStatus == rankedStatuses.NEED_UPDATE or beatmapInfo.rankedStatus == rankedStatuses.UNKNOWN:
				log.debug("Beatmap is not submitted/outdated/unknown. Score submission aborted.")
				return

		
			length = 0
			if s.passed:
				length = userUtils.getBeatmapTime(beatmapInfo.beatmapID)
			else:
				length = math.ceil(int(self.get_argument("ft")) / 1000)
			if UsingRelax: 	
				userUtils.incrementPlaytimeRX(userID, s.gameMode, length)
			elif UsingAuto:
				userUtils.incrementPlaytimeAP(userID, s.gameMode, length)
			else:
				userUtils.incrementPlaytime(userID, s.gameMode, length)
			
		
			midPPCalcException = None
			try:
				s.calculatePP()
			except Exception as e:
				log.error("Caught an exception in pp calculation, re-raising after saving score in db")
				s.pp = 0
				midPPCalcException = e

			RXLIST = [1009, 1096 ,1097, 1164]
			APLIST = [1254, 1164, 1252, 1163]
					
			# for fuck sake freddie
			gamers = [1317]
			if UsingRelax: 
				if (s.pp >= 5000 and s.gameMode == gameModes.STD) and userID not in RXLIST:
					userUtils.restrict(userID)
					userUtils.appendNotes(userID, "Restricted due to too high pp gain ({}pp)".format(s.pp))
					log.warning("**{}** ({}) has been restricted due to too high pp gain **({}pp)**".format(username, userID, s.pp), "cm")
			elif UsingAuto:
				if (s.pp >= 5000 and s.gameMode == gameModes.STD) and userID not in APLIST:
					userUtils.restrict(userID)
					userUtils.appendNotes(userID, "Restricted due to too high pp gain ({}pp)".format(s.pp))
					log.warning("**{}** ({}) has been restricted due to too high pp gain **({}pp)**".format(username, userID, s.pp), "cm")		
			else: # Vanilla
				if (s.pp >= 900 and s.gameMode == gameModes.STD) and userID not in gamers:
					userUtils.restrict(userID)
					userUtils.appendNotes(userID, "Restricted due to too high pp gain ({}pp)".format(s.pp))
					log.warning("**{}** ({}) has been restricted due to too high pp gain **({}pp)**".format(username, userID, s.pp), "cm")

			# Check notepad hack
				
			if bmk is None and bml is None:
				pass
			elif bmk != bml and restricted == False:
				userUtils.restrict(userID)
				userUtils.appendNotes(userID, "Restricted due to notepad hack")
				log.warning("**{}** ({}) has been restricted due to notepad hack".format(username, userID), "cm")
				return
			
			b = beatmap.beatmap(s.fileMd5, 0)
			if b.rankedStatus == rankedStatuses.PENDING:
				# Right before submitting the score, get the personal best score object (we need it for charts)
				if s.passed and s.oldPersonalBest > 0:
					if UsingRelax:
						oldPersonalBestRank = glob.personalBestCache.get(userID, s.fileMd5)
						if oldPersonalBestRank == 0:
							oldScoreboard = scoreboardRelaxScore.scoreboardRelax(username, s.gameMode, beatmapInfo, False)
							oldScoreboard.setPersonalBestRank()
							oldPersonalBestRank = max(oldScoreboard.personalBestRank, 0)
						oldPersonalBest = scoreRelax.score(s.oldPersonalBest, oldPersonalBestRank)
					elif UsingAuto:
						oldPersonalBestRank = glob.personalBestCache.get(userID, s.fileMd5)
						if oldPersonalBestRank == 0:
							oldScoreboard = scoreboardAutoScore.scoreboardAuto(username, s.gameMode, beatmapInfo, False)
							oldScoreboard.setPersonalBestRank()
							oldPersonalBestRank = max(oldScoreboard.personalBestRank, 0)
						oldPersonalBest = scoreAuto.score(s.oldPersonalBest, oldPersonalBestRank)
					else:
						oldPersonalBestRank = glob.personalBestCache.get(userID, s.fileMd5)
						if oldPersonalBestRank == 0:
							oldScoreboard = scoreboard.scoreboard(username, s.gameMode, beatmapInfo, False)
							oldScoreboard.setPersonalBestRank()
							oldPersonalBestRank = max(oldScoreboard.personalBestRank, 0)
						oldPersonalBest = score.score(s.oldPersonalBest, oldPersonalBestRank)
				else:
					oldPersonalBestRank = 0
					oldPersonalBest = None
			else:
				# Right before submitting the score, get the personal best score object (we need it for charts)
				if s.passed and s.oldPersonalBest > 0:
					if UsingRelax:
						oldPersonalBestRank = glob.personalBestCache.get(userID, s.fileMd5)
						if oldPersonalBestRank == 0:
							oldScoreboard = scoreboardRelax.scoreboardRelax(username, s.gameMode, beatmapInfo, False)
							oldScoreboard.setPersonalBestRank()
							oldPersonalBestRank = max(oldScoreboard.personalBestRank, 0)
						oldPersonalBest = scoreRelax.score(s.oldPersonalBest, oldPersonalBestRank)
					elif UsingAuto:
						oldPersonalBestRank = glob.personalBestCache.get(userID, s.fileMd5)
						if oldPersonalBestRank == 0:
							oldScoreboard = scoreboardAuto.scoreboardAuto(username, s.gameMode, beatmapInfo, False)
							oldScoreboard.setPersonalBestRank()
							oldPersonalBestRank = max(oldScoreboard.personalBestRank, 0)
						oldPersonalBest = scoreAuto.score(s.oldPersonalBest, oldPersonalBestRank)
					else:
						oldPersonalBestRank = glob.personalBestCache.get(userID, s.fileMd5)
						if oldPersonalBestRank == 0:
							oldScoreboard = scoreboard.scoreboard(username, s.gameMode, beatmapInfo, False)
							oldScoreboard.setPersonalBestRank()
							oldPersonalBestRank = max(oldScoreboard.personalBestRank, 0)
						oldPersonalBest = score.score(s.oldPersonalBest, oldPersonalBestRank)
				else:
					oldPersonalBestRank = 0
					oldPersonalBest = None


			s.saveScoreInDB()

			'''ignoreFlags = 4
			if glob.debug == True:
				# ignore multiple client flags if we are in debug mode
				ignoreFlags |= 8
			haxFlags = (len(scoreData[17])-len(scoreData[17].strip())) & ~ignoreFlags
			if haxFlags != 0 and restricted == False:
				userHelper.restrict(userID)
				userHelper.appendNotes(userID, "-- Restricted due to clientside anti cheat flag ({}) (cheated score id: {})".format(haxFlags, s.scoreID))
				log.warning("**{}** ({}) has been restricted due clientside anti cheat flag **({})**".format(username, userID, haxFlags), "cm")'''


			if s.score < 0 or s.score > (2 ** 63) - 1:
				userUtils.ban(userID)
				userUtils.appendNotes(userID, "Banned due to negative score (score submitter)")


			if s.gameMode == gameModes.MANIA and s.score > 1000000:
				userUtils.ban(userID)
				userUtils.appendNotes(userID, "Banned due to mania score > 1000000 (score submitter)")


			if ((s.mods & mods.DOUBLETIME) > 0 and (s.mods & mods.HALFTIME) > 0) \
					or ((s.mods & mods.HARDROCK) > 0 and (s.mods & mods.EASY) > 0)\
					or ((s.mods & mods.SUDDENDEATH) > 0 and (s.mods & mods.NOFAIL) > 0):
				userUtils.ban(userID)
				userUtils.appendNotes(userID, "Impossible mod combination {} (score submitter)".format(s.mods))


			if s.completed == 3 and "pl" in self.request.arguments:
				butterCake.bake(self, s)

			if UsingRelax:
				score_id_relax = s.scoreID 
			elif UsingAuto:
				score_id_auto = s.scoreID


			if s.passed and s.scoreID > 0:
				if "score" in self.request.files:

					if UsingRelax:
						log.debug("Saving replay ({})...".format(score_id_relax))
						replay = self.request.files["score"][0]["body"]
						with open(".data/replays_relax/replay_{}.osr".format(score_id_relax), "wb") as f:
							f.write(replay)
					elif UsingAuto:
						log.debug("Saving replay ({})...".format(score_id_auto))
						replay = self.request.files["score"][0]["body"]
						with open(".data/replays_auto/replay_{}.osr".format(score_id_auto), "wb") as f:
							f.write(replay)
					else:
						log.debug("Saving replay ({})...".format(s.scoreID))
						replay = self.request.files["score"][0]["body"]
						with open(".data/replays/replay_{}.osr".format(s.scoreID), "wb") as f:
							f.write(replay)


				else:

					if not restricted:
						userUtils.restrict(userID)
						userUtils.appendNotes(userID, "Restricted due to missing replay while submitting a score "
													  "(most likely he used a score submitter)")
						log.warning("**{}** ({}) has been restricted due to replay not found on map {}".format(
							username, userID, s.fileMd5
						), "cm")

			beatmap.incrementPlaycount(s.fileMd5, s.passed)

			if s.scoreID:
				glob.redis.publish("api:score_submission", s.scoreID)
			if midPPCalcException is not None:
				raise ppCalcException(midPPCalcException)

			if s.passed:
				
				oldUserData = glob.userStatsCache.get(userID, s.gameMode)
				oldRank = userUtils.getGameRank(userID, s.gameMode)

			log.debug("Updating {}'s stats...".format(username))
			if UsingRelax:	
				userUtils.updateStatsRx(userID, s)
			if UsingAuto:	
				userUtils.updateStatsAp(userID, s)
			else:
				userUtils.updateStats(userID, s)

			# Get "after" stats for ranking panel
			# and to determine if we should update the leaderboard
			# (only if we passed that song)
			if s.passed:

				# Get new stats
				if UsingRelax:
					newUserData = userUtils.getUserStatsRx(userID, s.gameMode)
					glob.userStatsCache.update(userID, s.gameMode, newUserData)
					leaderboardHelperRelax.update(userID, newUserData["pp"], s.gameMode)
					maxCombo = 0
				elif UsingAuto:
					newUserData = userUtils.getUserStatsAp(userID, s.gameMode)
					glob.userStatsCache.update(userID, s.gameMode, newUserData)
					leaderboardHelperAuto.update(userID, newUserData["pp"], s.gameMode)	
					maxCombo = 0		
				else:
					newUserData = userUtils.getUserStats(userID, s.gameMode)
					glob.userStatsCache.update(userID, s.gameMode, newUserData)
					leaderboardHelper.update(userID, newUserData["pp"], s.gameMode)	
					maxCombo = userUtils.getMaxCombo(userID, s.gameMode)			
				

			userUtils.updateLatestActivity(userID)

			# IP log
			userUtils.IPLog(userID, ip)

			# Score submission and stats update done
			log.debug("Score submission and user stats update done!")

			# Score has been submitted, do not retry sending the score if
			# there are exceptions while building the ranking panel
			keepSending = True

			# At the end, check achievements
			if s.passed:
				new_achievements = secret.achievements.utils.unlock_achievements(s, beatmapInfo, newUserData)

			# Output ranking panel only if we passed the song
			# and we got valid beatmap info from db
			if beatmapInfo is not None and beatmapInfo != False and s.passed:
				log.debug("Started building ranking panel")

				# Trigger bancho stats cache update
				glob.redis.publish("peppy:update_cached_stats", userID)

				# Get personal best after submitting the score
				if UsingRelax:
					newScoreboard = scoreboardRelax.scoreboardRelax(username, s.gameMode, beatmapInfo, False)
					newScoreboard.setPersonalBestRank()
					personalBestID = newScoreboard.getPersonalBestID()
					currentPersonalBest = scoreRelax.score(personalBestID, newScoreboard.personalBestRank)
				elif UsingAuto:
					newScoreboard = scoreboardAuto.scoreboardAuto(username, s.gameMode, beatmapInfo, False)
					newScoreboard.setPersonalBestRank()
					personalBestID = newScoreboard.getPersonalBestID()
					currentPersonalBest = scoreAuto.score(personalBestID, newScoreboard.personalBestRank)
				else:
					newScoreboard = scoreboard.scoreboard(username, s.gameMode, beatmapInfo, False)
					newScoreboard.setPersonalBestRank()
					personalBestID = newScoreboard.getPersonalBestID()
					currentPersonalBest = score.score(personalBestID, newScoreboard.personalBestRank)


				# Get rank info (current rank, pp/score to next rank, user who is 1 rank above us)
				if bool(s.mods & 128):
					rankInfo = leaderboardHelperRelax.getRankInfo(userID, s.gameMode)
				elif UsingAuto:
					rankInfo = leaderboardHelperAuto.getRankInfo(userID, s.gameMode)				
				else:
					rankInfo = leaderboardHelper.getRankInfo(userID, s.gameMode)

				if newCharts:
					log.debug("Using new charts")
					dicts = [
						collections.OrderedDict([
							("beatmapId", beatmapInfo.beatmapID),
							("beatmapSetId", beatmapInfo.beatmapSetID),
							("beatmapPlaycount", beatmapInfo.playcount + 1),
							("beatmapPasscount", beatmapInfo.passcount + (s.completed == 3)),
							("approvedDate", beatmapInfo.rankingDate)
						]),
						BeatmapChart(
							oldPersonalBest if s.completed == 3 else currentPersonalBest,
							currentPersonalBest if s.completed == 3 else s,
							beatmapInfo.beatmapID,
						),
						OverallChart(
							userID, oldUserData, newUserData, maxCombo, s, new_achievements, oldRank, rankInfo["currentRank"]
						)
					]
				else:
					log.debug("Using old charts")
					dicts = [
						collections.OrderedDict([
							("beatmapId", beatmapInfo.beatmapID),
							("beatmapSetId", beatmapInfo.beatmapSetID),
							("beatmapPlaycount", beatmapInfo.playcount),
							("beatmapPasscount", beatmapInfo.passcount),
							("approvedDate", beatmapInfo.rankingDate)
						]),
						collections.OrderedDict([
							("chartId", "overall"),
							("chartName", "Overall Ranking"),
							("chartEndDate", ""),
							("beatmapRankingBefore", oldPersonalBestRank),
							("beatmapRankingAfter", newScoreboard.personalBestRank),
							("rankedScoreBefore", oldUserData["rankedScore"]),
							("rankedScoreAfter", newUserData["rankedScore"]),
							("totalScoreBefore", oldUserData["totalScore"]),
							("totalScoreAfter", newUserData["totalScore"]),
							("playCountBefore", newUserData["playcount"]),
							("accuracyBefore", float(oldUserData["accuracy"])/100),
							("accuracyAfter", float(newUserData["accuracy"])/100),
							("rankBefore", oldRank),
							("rankAfter", rankInfo["currentRank"]),
							("toNextRank", rankInfo["difference"]),
							("toNextRankUser", rankInfo["nextUsername"]),
							("achievements", ""),
							("achievements-new", secret.achievements.utils.achievements_response(new_achievements)),
							("onlineScoreId", s.scoreID)
						])
					]
				output = "\n".join(zingonify(x) for x in dicts)

				log.debug("Generated output for online ranking screen!")
				log.debug(output)
				if UsingRelax:
					if beatmapInfo.rankedStatus == rankedStatuses.PENDING:
						announceMsg = "[RELAX] (UNRANKED) [https://minase.tk/?u={} {}] achieved rank #1({}) on [https://osu.ppy.sh/b/{} {}] ({})".format(
									userID,
									username.encode().decode("ASCII", "ignore"),
									beatmapInfo.beatmapID,
									s.pp,
									beatmapInfo.songName.encode().decode("ASCII", "ignore"),
									gameModes.getGamemodeFull(s.gameMode)
								)
						userLogMsg = " Achieved Unranked Relax #{} rank on ".format(newScoreboard.personalBestRank)
					else:
						announceMsg = "[RELAX] [https://minase.tk/?u={} {}] achieved rank #1 on [https://osu.ppy.sh/b/{} {}] ({})".format(
									userID,
									username.encode().decode("ASCII", "ignore"),
									beatmapInfo.beatmapID,
									beatmapInfo.songName.encode().decode("ASCII", "ignore"),
									gameModes.getGamemodeFull(s.gameMode)
								)
						userLogMsg = " Achieved Relax #{} rank on ".format(newScoreboard.personalBestRank)
				elif UsingAuto:
					if beatmapInfo.rankedStatus == rankedStatuses.PENDING:
						announceMsg = "[AUTOPILOT] (UNRANKED) [https://minase.tk/?u={} {}] achieved rank #1 on [https://osu.ppy.sh/b/{} {}] ({})".format(
									userID,
									username.encode().decode("ASCII", "ignore"),
									beatmapInfo.beatmapID,
									beatmapInfo.songName.encode().decode("ASCII", "ignore"),
									gameModes.getGamemodeFull(s.gameMode)
								)
						userLogMsg = " Achieved Unranked Autopilot #{} rank on ".format(newScoreboard.personalBestRank)
					else:
						announceMsg = "[AUTOPILOT] [https://minase.tk/?u={} {}] achieved rank #1 on [https://osu.ppy.sh/b/{} {}] ({})".format(
									userID,
									username.encode().decode("ASCII", "ignore"),
									beatmapInfo.beatmapID,
									beatmapInfo.songName.encode().decode("ASCII", "ignore"),
									gameModes.getGamemodeFull(s.gameMode)
								)
						userLogMsg = " Achieved Autopilot #{} rank on ".format(newScoreboard.personalBestRank)
				else:
					if beatmapInfo.rankedStatus == rankedStatuses.PENDING:
						announceMsg = "[VANILLA] (UNRANKED) [https://minase.tk/?u={} {}] achieved rank #1({}pp) on [https://osu.ppy.sh/b/{} {}] ({})".format(
									userID,
									username.encode().decode("ASCII", "ignore"),
									beatmapInfo.beatmapID,
									round(s.pp),
									beatmapInfo.songName.encode().decode("ASCII", "ignore"),
									gameModes.getGamemodeFull(s.gameMode)
								)
						userLogMsg = " Achieved Unranked Vanilla #{} rank on ".format(newScoreboard.personalBestRank)
					else:
						announceMsg = "[VANILLA] [https://minase.tk/?u={} {}] achieved rank #1({}pp) on [https://osu.ppy.sh/b/{} {}] ({})".format(
									userID,
									username.encode().decode("ASCII", "ignore"),
									round(s.pp),
									beatmapInfo.beatmapID,
									beatmapInfo.songName.encode().decode("ASCII", "ignore"),
									gameModes.getGamemodeFull(s.gameMode)
								)
						userLogMsg = " Achieved Vanilla #{} rank on ".format(newScoreboard.personalBestRank)
					
	


				# send message to #announce if we're rank #1
				if newScoreboard.personalBestRank < 101 and s.completed == 3 and restricted == False and beatmapInfo.rankedStatus >= rankedStatuses.PENDING:
						#userUtils.logUserLog(userLogMsg, s.fileMd5, userID, s.gameMode, s.scoreID)
						log.warning("{} got a rank #{}".format(username, newScoreboard.personalBestRank))
						if newScoreboard.personalBestRank < 2:	
								#log.info(newScoreboard.scores) #
								#userUtils.logUserLogX("has lost first place Vanilla on ",s.fileMd5, newScoreboard.scores[1].playerUserID, s.gameMode, s.rank)	
								params = urlencode({"k": glob.conf.config["server"]["apikey"], "to": "#announce", "msg": announceMsg})
								log.warning(params)
								requests.get("{}/api/v1/fokabotMessage?{}".format(glob.conf.config["server"]["banchourl"], params))
				if UsingRelax:
					server = "Relax"
				elif UsingAuto:
					server = "Auto"
				else:
					server = "Vanilla"

				ppGained = newUserData["pp"] - oldUserData["pp"]
				gainedRanks = oldRank - rankInfo["currentRank"]
				# Write message to client
				self.write(output)
			else:
				# No ranking panel, send just "ok"
				self.write("ok")

			newUsername = glob.redis.get("ripple:change_username_pending:{}".format(userID))
			if newUsername is not None:
				log.debug("Sending username change request for user {} to Bancho".format(userID))
				glob.redis.publish("peppy:change_username", json.dumps({
					"userID": userID,
					"newUsername": newUsername.decode("utf-8")
				}))

			# Datadog stats
			glob.dog.increment(glob.DATADOG_PREFIX+".submitted_scores")
		except exceptions.invalidArgumentsException:
			pass
		except exceptions.loginFailedException:
			self.write("error: pass")
		except exceptions.need2FAException:
			self.set_status(408)
			self.write("error: 2fa")
		except exceptions.userBannedException:
			self.write("error: ban")
		except exceptions.noBanchoSessionException:
			self.set_status(408)
			self.write("error: pass")
		except:
			try:
				log.error("Unknown error in {}!\n```{}\n{}```".format(MODULE_NAME, sys.exc_info(), traceback.format_exc()))
				if glob.sentry:
					yield tornado.gen.Task(self.captureException, exc_info=True)
			except:
				pass

			if keepSending:
				self.set_status(408)
