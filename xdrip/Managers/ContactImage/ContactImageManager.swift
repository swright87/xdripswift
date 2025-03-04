import Foundation
import os
import Contacts

class ContactImageManager: NSObject {
    
    // MARK: - private properties
    
    /// CoreDataManager to use
    private let coreDataManager:CoreDataManager
    
    /// BgReadingsAccessor instance
    private let bgReadingsAccessor:BgReadingsAccessor
    
    /// for logging
    private var log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryContactImageManager)
    
    private var queue = DispatchQueue(label: "PhoneContactUpdater")
    
    private let debouncer = Debouncer(delay: 3.0) // 3-second debounce
    
    private var workItem: DispatchWorkItem?
    
    /// to work with contacts
    let contactStore = CNContactStore()
    
    // MARK: - initializer
    
    init(coreDataManager: CoreDataManager) {
        self.coreDataManager = coreDataManager
        self.bgReadingsAccessor = BgReadingsAccessor(coreDataManager: coreDataManager)
        
        super.init()
        
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.enableContactImage.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.displayTrendInContactImage.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.useHighContrastContactImage.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.bloodGlucoseUnitIsMgDl.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.isMaster.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.followerBackgroundKeepAliveType.rawValue, options: .new, context: nil)
        
        
    }
    
    // MARK: - public functions
    
    /// process new readings
    public func processNewReading() {
        updateContact()
    }
    
    // MARK: - overriden functions
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        guard let keyPath = keyPath else {return}
        
        if let keyPathEnum = UserDefaults.Key(rawValue: keyPath) {
            evaluateUserDefaultsChange(keyPathEnum: keyPathEnum)
        }
        
    }
    
    // MARK: - private functions
    
    /// used by observevalue for UserDefaults.Key
    private func evaluateUserDefaultsChange(keyPathEnum: UserDefaults.Key) {
        updateContact()
    }
    
    /// this function will perform the following actions:
    /// - first check that it should do something and the user has given access/authorization to the app to work with the device contacts
    /// - create an image view based upon the recent glucose value(s)
    /// - check if a valid contact (with the same name as the app) exists. If so, update it with a png image of the image view
    /// - if a valid contact doesn't yet exist, create one with the app name and add a png image of the image view
    /// - schedule a 5-6 minute timer to repeat the above (just in case the function isn't updated again by the root view controller)
    private func updateContact() {
        debouncer.debounce {
            self.workItem?.cancel()
            self.workItem = nil
            
            // check that access to contacts is authorized by the user
            guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
                // if it isn't, and the user has enabled the feature, then disable it
                if UserDefaults.standard.enableContactImage {
                    trace("in updateContact, access to contacts is not authorized so setting enableContactImage to false", log: self.log, category: ConstantsLog.categoryContactImageManager, type: .info)
                    
                    UserDefaults.standard.enableContactImage = false
                }
                return
            }
            
            // create a contact image view
            // get 2 last Readings, with a calculatedValue
            let lastReading = self.bgReadingsAccessor.get2LatestBgReadings(minimumTimeIntervalInMinutes: 4.0)
            var contactImageView: ContactImageView
            
            // disable the image (show "OFF") if the function is disabled or if the user is in follower mode with background keep-alive disabled
            // as otherwise it would always be out of date
            let disableContactImage: Bool = !UserDefaults.standard.enableContactImage || (!UserDefaults.standard.isMaster && UserDefaults.standard.followerBackgroundKeepAliveType == .disabled)
            
            if lastReading.count > 0  {
                let valueIsUpToDate = abs(lastReading[0].timeStamp.timeIntervalSinceNow) < 7 * 60
                
                contactImageView = ContactImageView(bgValue: lastReading[0].calculatedValue, isMgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl, slopeArrow: UserDefaults.standard.displayTrendInContactImage ? lastReading[0].slopeArrow() : "", bgRangeDescription: lastReading[0].bgRangeDescription(), valueIsUpToDate: valueIsUpToDate, useHighContrastContactImage: UserDefaults.standard.useHighContrastContactImage, disableContactImage:  disableContactImage)
                
                // schedule an update in 5 min 15 seconds - if no new data is received until then, the empty value will get rendered into the contact (this update will be canceled if new data is received)
                self.workItem = DispatchWorkItem(block: {
                    trace("in updateContact, no updates received for more than 5 minutes", log: self.log, category: ConstantsLog.categoryContactImageManager, type: .error)
                    self.updateContact()
                })
                
                DispatchQueue.main.asyncAfter(deadline: .now() + (5 * 60) + 15, execute: self.workItem!)
            } else {
                // create an 'empty' image view if there is no BG data to show
                contactImageView = ContactImageView(bgValue: 0, isMgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl, slopeArrow: "", bgRangeDescription: .inRange, valueIsUpToDate: false, useHighContrastContactImage: false, disableContactImage:  disableContactImage)
            }
            
            // we're going to use the app name as the given name of the contact we want to use/create/update
            let keyToFetch = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactImageDataKey] as [CNKeyDescriptor]
            let predicate = CNContact.predicateForContacts(matchingName: ConstantsHomeView.applicationName)
            let saveRequest = CNSaveRequest()
            
            let updatedString = (UserDefaults.standard.isMaster ? UserDefaults.standard.activeSensorDescription ?? "Updated" : UserDefaults.standard.followerDataSourceType.fullDescription) + ": \(Date().formatted(date: .omitted, time: .shortened))"
            
            // now let's try and find an existing contact with the same name as the app name
            // we'll search for all results and then just use the first one for now
            // we do it this way so that in the future we want to add a descriptor to the family name to have various contact images (such as "BG", "IOB", "COB" as needed)
            if let contacts = try? self.contactStore.unifiedContacts(matching: predicate, keysToFetch: keyToFetch), let contact = contacts.first {
                
                if lastReading.count > 0 {
                    trace("in updateContact, '%{public}@' contact found. Updating the contact image to %{public}@ %{public}@.", log: self.log, category: ConstantsLog.categoryContactImageManager, type: .info, ConstantsHomeView.applicationName, lastReading[0].calculatedValue.mgDlToMmolAndToString(mgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl), UserDefaults.standard.bloodGlucoseUnitIsMgDl ? Texts_Common.mgdl : Texts_Common.mmol)
                }
                
                // create a mutableContact from the existing contact so that we can modify it
                guard let mutableContact = contact.mutableCopy() as? CNMutableContact else { return }
                
                mutableContact.imageData = contactImageView.getImage().pngData()
                mutableContact.organizationName = updatedString
                
                // we'll update the existing contact with the new data
                saveRequest.update(mutableContact)
            } else {
                trace("in updateContact, no existing contact found. Creating a new contact called '%{public}@' and adding a contact image with %{public}@ %{public}@.", log: self.log, category: ConstantsLog.categoryContactImageManager, type: .info, ConstantsHomeView.applicationName, lastReading[0].calculatedValue.mgDlToMmolAndToString(mgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl), UserDefaults.standard.bloodGlucoseUnitIsMgDl ? Texts_Common.mgdl : Texts_Common.mmol)
                
                // create a new mutable contact instance and assign properties to it
                let contact = CNMutableContact()
                var appVersion: String = " "
                
                if let dictionary = Bundle.main.infoDictionary, let version = dictionary["CFBundleShortVersionString"] as? String {
                    appVersion += "v" + version
                }
                
                contact.givenName = ConstantsHomeView.applicationName
                contact.imageData = contactImageView.getImage().pngData()
                contact.organizationName = updatedString
                contact.note = "\(Texts_SettingsView.contactImageCreatedByString) \(ConstantsHomeView.applicationName)\(appVersion) - \(Date().formatted(date: .abbreviated, time: .shortened))"
                
                // add a new contact to the device contacts
                saveRequest.add(contact, toContainerWithIdentifier: nil)
            }
            
            // now execute the saveRequest - either to update an existing contact, or to create a new one
            self.executeSaveRequest(saveRequest: saveRequest)
        }
    }
    
    func deleteContact() {
        // we're going to use the app name as the given name of the contact we want to use/create/update
        let keyToFetch = [CNContactGivenNameKey] as [CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: ConstantsHomeView.applicationName)
        let saveRequest = CNSaveRequest()
        
        if let contacts = try? self.contactStore.unifiedContacts(matching: predicate, keysToFetch: keyToFetch), let contact = contacts.first {
            trace("in deleteContact, existing contact found. Will try and delete it.", log: self.log, category: ConstantsLog.categoryContactImageManager, type: .info)
            
            let mutableContact = contact.mutableCopy() as! CNMutableContact
            saveRequest.delete(mutableContact)
            
            executeSaveRequest(saveRequest: saveRequest)
        }
    }
    
    private func executeSaveRequest(saveRequest: CNSaveRequest) {
        // now execute the saveRequest - to delete the existing contact
        do {
            try self.contactStore.execute(saveRequest)
        } catch let error as NSError {
            var details: String?
            
            if error.domain == CNErrorDomain {
                switch error.code {
                case CNError.authorizationDenied.rawValue:
                    details = "Authorization denied"
                case CNError.communicationError.rawValue:
                    details = "Communication error"
                case CNError.insertedRecordAlreadyExists.rawValue:
                    details = "Record already exists"
                case CNError.dataAccessError.rawValue:
                    details = "Data access error"
                default:
                    details = "Code \(error.code)"
                }
            }
            trace("in executeSaveRequest, failed to update/add/delete the contact - %{public}@: %{public}@", log: self.log, category: ConstantsLog.categoryContactImageManager, type: .error, details ?? "no details", error.localizedDescription)
        } catch {
            trace("in executeSaveRequest, failed to update/add/delete the contact: %{public}@", log: self.log, category: ConstantsLog.categoryContactImageManager, type: .error, error.localizedDescription)
        }
    }
}

extension ContactImageManager {
    class Debouncer {
        private var workItem: DispatchWorkItem?
        private let queue: DispatchQueue
        private let delay: TimeInterval
        private var lastExecutedAt: Date?
        
        init(delay: TimeInterval, queue: DispatchQueue = DispatchQueue.main) {
            self.delay = delay
            self.queue = queue
        }
        
        func debounce(_ block: @escaping () -> Void) {
            workItem?.cancel()
            
            let workItem = DispatchWorkItem(block: {
                block()
                
                self.lastExecutedAt = .now
            })
            
            self.workItem = workItem
            
            let thisDelay: TimeInterval
            
            if lastExecutedAt == nil {
                thisDelay = 0
            } else {
                let sinceLast = Date.now.timeIntervalSince(lastExecutedAt!)
                
                if sinceLast > delay {
                    thisDelay = 0
                } else {
                    thisDelay = delay - sinceLast
                }
            }
            
            queue.asyncAfter(deadline: .now() + thisDelay, execute: workItem)
        }
    }
    
}
