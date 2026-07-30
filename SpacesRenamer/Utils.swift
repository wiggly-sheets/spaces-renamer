//
//  Utils.swift
//  SpacesRenamer
//
//  Created by Alex Beals on 11/15/17.
//  Copyright © 2018 Alex Beals. All rights reserved.

import Foundation

class Utils {
  static let libraryPath = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first!
  // Keep the legacy shared location because the injected Dock bundle reads it directly.
  static let legacyContainerPath = Utils.libraryPath.appending("/Containers/com.alexbeals.spacesrenamer")
  static let customNamesPlist = legacyContainerPath.appending("/com.alexbeals.spacesrenamer.plist")
  static let listOfSpacesPlist = legacyContainerPath.appending("/com.alexbeals.spacesrenamer.currentspaces.plist")
  static let spacesPath = Utils.libraryPath.appending("/Preferences/com.apple.spaces.plist")
  
  static let escapeKey: UInt16 = 0x35
  
}
