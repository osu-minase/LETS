import tornado.gen
import tornado.web
from objects import glob
from common.web import requestsManager
from constants import exceptions
from helpers import replayHelper
from helpers import replayHelperAuto
from helpers import replayHelperRelax
from common.sentry import sentry

MODULE_NAME = "get_full_replay"
class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /replay/
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	@sentry.captureTornado
	def asyncGet(self, replayID):
		try:
			#try to found vanilla replay
			
			try:
				fullReplay = replayHelper.buildFullReplay(scoreID=replayID)
			except (exceptions.fileNotFoundException, exceptions.scoreNotFoundError):
				#try found relax replay (yes, try, try, try)
				try:
					fullReplay = replayHelperRelax.buildFullReplay(scoreID=replayID)
				except (exceptions.fileNotFoundException, exceptions.scoreNotFoundError):
					try:
						fullReplay = replayHelperAuto.buildFullReplay(scoreID=replayID)
					except (exceptions.fileNotFoundException, exceptions.scoreNotFoundError):
						raise exceptions.fileNotFoundException(MODULE_NAME, None)
			self.write(fullReplay)
			self.add_header("Content-type", "application/octet-stream")
			self.set_header("Content-length", len(fullReplay))
			self.set_header("Content-Description", "File Transfer")
			self.set_header("Content-Disposition", "attachment; filename=\"{}.osr\"".format(replayID))
		except (exceptions.fileNotFoundException, exceptions.scoreNotFoundError):
			self.write("Replay not found")