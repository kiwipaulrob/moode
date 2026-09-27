#!/usr/bin/python3
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2023 @bitkeeper GitHub
# Copyright 2026 The moOde audio player project / Tim Curtis
#
# CLI script for updating CamillaDSP volume.
# Based on the mpd2cdspvolume.py script by @bitlab
#

import os
from typing import Callable, Optional
import argparse
import time
import signal
import logging
import time
import yaml
import configparser
from pathlib import Path
from math import log10, exp, log
import camilladsp

VERSION = "1.0.0"

class CamillaDSPVolumeUpdater:
	"""Updates CamillaDSP volume
	   When cdsp isn't running and a volume state file for alsa_cdsp is provided it is updated
	"""

	# Used as default statefile value, when not present or invalid
	CDSP_STATE_TEMPLATE = {
		'config_path': '/usr/share/camilladsp/working_config.yml',
		'mute': [ False, False, False, False, False],
		'volume': [ -6.0, -6.0, -6.0, -6.0, -6.0]
	}

	def __init__(self, volume_state_file: Optional[Path]=None, host: str='127.0.0.1', port:int=1234):
		self._volume_state_file: Optional[Path] = volume_state_file
		self._cdsp = camilladsp.CamillaClient(host, port)
		if volume_state_file:
			logging.info('Volume state file: "%s"', volume_state_file )

	def check_cdsp_statefile(self) -> bool:
		""" Check if it exists and is valid. If not create a valid one"""
		try:
			if self._volume_state_file and self._volume_state_file.is_file() is False:
				logging.info('Create statefile %s', self._volume_state_file)
				cdsp.update_cdsp_statefile(0, False)
			elif self._volume_state_file.is_file() is True:
				cdsp_state = yaml.load(self._volume_state_file.read_text(), Loader=yaml.Loader)
				if isinstance(cdsp_state, dict) is False:
					logging.info('Statefile %s content not valid recreate it', self._volume_state_file)
					cdsp.update_cdsp_statefile(0, False)
		except FileNotFoundError as e:
			logging.error('Couldn\'t create state file "%s", prob basedir doesn\'t exists.', self._volume_state_file)
			return False
		except PermissionError as e:
			logging.error('Couldn\'t write state to "%s", prob incorrect owner rights of dir.', self._volume_state_file)
			return False

		return True

	def update_cdsp_statefile(self, main_volume: float=-6.0, main_mute: bool=False):
		""" Update statefile from camilladsp. Used for CamillaDSP 2.x and higher."""
		logging.info('update volume state file: %.2f dB, mute: %d', main_volume ,main_mute)
		cdsp_state = dict(CamillaDSPVolumeUpdater.CDSP_STATE_TEMPLATE)
		if self._volume_state_file:
			try:
				if self._volume_state_file.exists():
					data = yaml.load(self._volume_state_file.read_text(), Loader=yaml.Loader)
					if isinstance(data, dict):
						cdsp_state = data
					else:
						logging.warning('No valid state file content, overwrite it')
				else:
					logging.info('No state file present, create one')

				cdsp_state['volume'][0] = main_volume
				cdsp_state['mute'][0] = main_mute

				self._volume_state_file.write_text(yaml.dump(cdsp_state, indent=8, explicit_start=True))
			except FileNotFoundError as e:
				logging.error('Couldn\'t create state file "%s", prob basedir doesn\'t exists.', self._volume_state_file)
			except PermissionError as e:
				logging.error('Couldn\'t write state to "%s", prob incorrect owner rights of dir.', self._volume_state_file)

	def lin_vol_curve(self, perc: int, dynamic_range: float= 60.0) -> float:
		'''
		Generates from a percentage a dBA, based on a curve with a dynamic_range.
		Curve calculations coming from: https://www.dr-lex.be/info-stuff/volumecontrols.html

		@perc (int) : linear value between 0-100
		@dynamic_range (float) : dynamic range of the curve
		return (float): Value in dBA
		'''
		if perc == 0:
			y = 0.000001
		else:
			x = perc/100.0
			y = pow(10, dynamic_range/20)
			a = 1/y
			b = log(y)
			y=a*exp(b*(x))
			if x < .1:
				y = x*10*a*exp(0.1*b)
			if y == 0:
				y = 0.000001

		return 20* log10(y)

	def update_cdsp_volume(self, volume_db: float):
		try:
			if self._cdsp.is_connected() is False:
				self._cdsp.connect()

			self._cdsp.volume.set_main_volume(volume_db)
			time.sleep(0.2)
			cdsp_actual_volume = self._cdsp.volume.main_volume()
			logging.info('volume set to %.2f [readback = %.2f] dB', volume_db, cdsp_actual_volume)

			# Correct issue when volume is not the required one (issue with cdsp 2.0)
			if abs(cdsp_actual_volume-volume_db) > .2:
				# logging.info('volume incorrect !')
				self._cdsp.volume.set_main_volume(volume_db)
			return True
		except (ConnectionRefusedError, IOError) as e:
			logging.info('no cdsp')
			self.update_cdsp_statefile(volume_db)
			return False

def get_cmdline_arguments():
	parser = argparse.ArgumentParser(description = 'Update CamillaDSP volume')

	parser.add_argument('-V', '--version', action='version', version='%(prog)s {}'.format(VERSION))
	parser.add_argument('-v', '--verbose', action='store_true',
		help = 'Show debug output.')
	parser.add_argument('--cdsp_host', default='127.0.0.1',
		help = 'Host running CamillaDSP. (default: 127.0.0.1)')
	parser.add_argument('--cdsp_port', default=1234, type=int,
		help = 'Port used by CamillaDSP. (default: 1234)')
	parser.add_argument('-s', '--volume_state_file', type=Path, default='/var/lib/cdsp/statefile.yml',
		help = 'File where the volume state is stored. (default: /var/lib/cdsp/statefile.yml)')
	parser.add_argument('-c', '--config', type=Path, default='/etc/mpd2cdspvolume.config',
		help = 'File where the config is stored. (default: /etc/mpd2cdspvolume.config)')
	parser.add_argument('-l', '--volume_level', type=int, required=True,
		help = 'Volume level to be set. Range 0-100.')

	args = parser.parse_args()
	return args

def get_config(config_file: Path):
	dynamic_range = None
	volume_offset = None

	if config_file and config_file.is_file():
		config = configparser.ConfigParser()
		config.read(config_file)

		if 'default' in config and 'dynamic_range' in config['default']:
			dynamic_range = int(config['default']['dynamic_range'])
		if 'default' in config and 'volume_offset' in config['default']:
			volume_offset = float(config['default']['volume_offset'])
	return dynamic_range, volume_offset

if __name__ == "__main__":
	args = get_cmdline_arguments()
	if args.verbose:
		logging.basicConfig(level=logging.INFO)

	logging.info('Run cdsp_volume_update')

	dynamic_range: Optional[int]= None
	volume_offset: Optional[float]= None

	config_file = args.config
	if config_file and config_file.is_file() is False:
		logging.error('Supplied config file "%s" can\'t be read.', config_file)
		exit(1)
	elif config_file:
		logging.info('config file: "%s"', config_file )
		dynamic_range, volume_offset = get_config(config_file)

	state_file = args.volume_state_file
	cdsp = CamillaDSPVolumeUpdater(state_file, host=args.cdsp_host, port=args.cdsp_port)
	if cdsp.check_cdsp_statefile() is False:
		exit(1)

	volume = float(args.volume_level)
	volume_db = cdsp.lin_vol_curve(volume, dynamic_range) - abs(volume_offset)
	logging.info('vol update = %d : %.2f dB', volume, volume_db)
	cdsp.update_cdsp_volume(volume_db)
