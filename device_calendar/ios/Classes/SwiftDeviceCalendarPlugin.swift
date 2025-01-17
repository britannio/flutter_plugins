import Flutter
import UIKit
import EventKit

extension Date {
    var millisecondsSinceEpoch: Double { return self.timeIntervalSince1970 * 1000.0 }
}

public class SwiftDeviceCalendarPlugin: NSObject, FlutterPlugin {
    
    struct Calendar: Codable {
        let id: String
        let name: String
        let isReadOnly: Bool
    }
    
    struct Event: Codable {
        let eventId: String
        let calendarId: String
        let title: String
        let description: String?
        let start: Int64
        let end: Int64
        let allDay: Bool
        let attendees: [Attendee]
        let location: String?
        let recurrenceRule: RecurrenceRule?
    }
    
    struct RecurrenceRule: Codable {
        let recurrenceFrequency: Int
        let totalOccurrences: Int?
        let interval: Int
        let endDate: Int64?
    }
    
    struct Attendee: Codable {
        let name: String
    }
    
    static let channelName = "plugins.builttoroam.com/device_calendar"
    let notFoundErrorCode = "404"
    let notAllowed = "405"
    let genericError = "500"
    let unauthorizedErrorCode = "401"
    let unauthorizedErrorMessage = "The user has not allowed this application to modify their calendar(s)"
    let calendarNotFoundErrorMessageFormat = "The calendar with the ID %@ could not be found"
    let calendarReadOnlyErrorMessageFormat = "Calendar with ID %@ is read-only"
    let eventNotFoundErrorMessageFormat = "The event with the ID %@ could not be found"
    let eventStore = EKEventStore()
    let requestPermissionsMethod = "requestPermissions"
    let hasPermissionsMethod = "hasPermissions"
    let retrieveCalendarsMethod = "retrieveCalendars"
    let retrieveEventsMethod = "retrieveEvents"
    let createOrUpdateEventMethod = "createOrUpdateEvent"
    let deleteEventMethod = "deleteEvent"
    let calendarIdArgument = "calendarId"
    let startDateArgument = "startDate"
    let endDateArgument = "endDate"
    let eventIdArgument = "eventId"
    let eventIdsArgument = "eventIds"
    let eventTitleArgument = "eventTitle"
    let eventDescriptionArgument = "eventDescription"
    let eventStartDateArgument =  "eventStartDate"
    let eventEndDateArgument = "eventEndDate"
    let eventLocationArgument = "eventLocation"
    let recurrenceRuleArgument = "recurrenceRule"
    let recurrenceFrequencyArgument = "recurrenceFrequency"
    let totalOccurrencesArgument = "totalOccurrences"
    let intervalArgument = "interval"
    let validFrequencyTypes = [EKRecurrenceFrequency.daily, EKRecurrenceFrequency.weekly, EKRecurrenceFrequency.monthly, EKRecurrenceFrequency.yearly]
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
        let instance = SwiftDeviceCalendarPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case requestPermissionsMethod:
            requestPermissions(result)
        case hasPermissionsMethod:
            hasPermissions(result)
        case retrieveCalendarsMethod:
            retrieveCalendars(result)
        case retrieveEventsMethod:
            retrieveEvents(call, result)
        case createOrUpdateEventMethod:
            createOrUpdateEvent(call, result)
        case deleteEventMethod:
            deleteEvent(call, result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func hasPermissions(_ result: FlutterResult) {
        let hasPermissions = self.hasPermissions()
        result(hasPermissions)
    }
    
    private func retrieveCalendars(_ result: @escaping FlutterResult) {
        checkPermissionsThenExecute(permissionsGrantedAction: {
            let ekCalendars = self.eventStore.calendars(for: .event)
            var calendars = [Calendar]()
            for ekCalendar in ekCalendars {
                let calendar = Calendar(id: ekCalendar.calendarIdentifier, name: ekCalendar.title, isReadOnly: !ekCalendar.allowsContentModifications)
                calendars.append(calendar)
            }
            
            self.encodeJsonAndFinish(codable: calendars, result: result)
        }, result: result)
    }
    
    private func retrieveEvents(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        checkPermissionsThenExecute(permissionsGrantedAction: {
            let arguments = call.arguments as! Dictionary<String, AnyObject>
            let calendarId = arguments[calendarIdArgument] as! String
            let startDateMillisecondsSinceEpoch = arguments[startDateArgument] as? NSNumber
            let endDateDateMillisecondsSinceEpoch = arguments[endDateArgument] as? NSNumber
            let eventIds = arguments[eventIdsArgument] as? [String]
            var events = [Event]()
            let specifiedStartEndDates = startDateMillisecondsSinceEpoch != nil && endDateDateMillisecondsSinceEpoch != nil
            if (specifiedStartEndDates) {
                let startDate = Date (timeIntervalSince1970: startDateMillisecondsSinceEpoch!.doubleValue / 1000.0)
                let endDate = Date (timeIntervalSince1970: endDateDateMillisecondsSinceEpoch!.doubleValue / 1000.0)
                let ekCalendar = self.eventStore.calendar(withIdentifier: calendarId)
                let predicate = self.eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: [ekCalendar!])
                let ekEvents = self.eventStore.events(matching: predicate)
                for ekEvent in ekEvents {
                    let event = createEventFromEkEvent(calendarId: calendarId, ekEvent: ekEvent)
                    events.append(event)
                }
            }
            
            if (eventIds == nil) {
                self.encodeJsonAndFinish(codable: events, result: result)
                return
            }
            
            if (specifiedStartEndDates) {
                events = events.filter({ (e) -> Bool in
                    e.calendarId == calendarId && eventIds!.contains(e.eventId)
                })
                
                self.encodeJsonAndFinish(codable: events, result: result)
                return
            }
            
            for eventId in eventIds! {
                let ekEvent = self.eventStore.event(withIdentifier: eventId)
                if(ekEvent == nil) {
                    continue
                }
                
                let event = createEventFromEkEvent(calendarId: calendarId, ekEvent: ekEvent!)
                events.append(event)
            }
            
            self.encodeJsonAndFinish(codable: events, result: result)
        }, result: result)
    }
    
    private func createEventFromEkEvent(calendarId: String, ekEvent: EKEvent) -> Event {
        var attendees = [Attendee]()
        if (ekEvent.attendees != nil) {
            for ekParticipant in ekEvent.attendees! {
                if(ekParticipant.name == nil) {
                    continue
                }
                
                let attendee = Attendee(name: ekParticipant.name!)
                attendees.append(attendee)
            }
            
        }
        var recurrenceRule: RecurrenceRule?
        if(ekEvent.hasRecurrenceRules) {
            let ekRecurrenceRule = ekEvent.recurrenceRules![0]
            var frequency: Int
            switch ekRecurrenceRule.frequency {
            case EKRecurrenceFrequency.daily:
                frequency = 0
            case EKRecurrenceFrequency.weekly:
                frequency = 1
            case EKRecurrenceFrequency.monthly:
                frequency = 2
            case EKRecurrenceFrequency.yearly:
                frequency = 3
            default:
                frequency = 0
            }
            
            var totalOccurrences: Int? = nil
            var endDate: Int64? = nil
            if(ekRecurrenceRule.recurrenceEnd?.occurrenceCount != nil) {
                totalOccurrences = ekRecurrenceRule.recurrenceEnd?.occurrenceCount
            }
            
            let endDateMs = ekRecurrenceRule.recurrenceEnd?.endDate?.millisecondsSinceEpoch
            if(endDateMs != nil) {
                endDate = Int64(exactly: endDateMs!)
            }
            
            recurrenceRule = RecurrenceRule(recurrenceFrequency: frequency, totalOccurrences: totalOccurrences, interval: ekRecurrenceRule.interval, endDate: endDate)
        }
        
        let event = Event(
            eventId: ekEvent.eventIdentifier,
            calendarId: calendarId,
            title: ekEvent.title,
            description: ekEvent.notes,
            start: Int64(ekEvent.startDate.millisecondsSinceEpoch),
            end: Int64(ekEvent.endDate.millisecondsSinceEpoch),
            allDay: ekEvent.isAllDay,
            attendees: attendees,
            location: ekEvent.location,
            recurrenceRule: recurrenceRule
        )
        return event
    }
    
    private func createOrUpdateEvent(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        checkPermissionsThenExecute(permissionsGrantedAction: {
            let arguments = call.arguments as! Dictionary<String, AnyObject>
            let calendarId = arguments[calendarIdArgument] as! String
            let eventId = arguments[eventIdArgument] as? String
            let startDateMillisecondsSinceEpoch = arguments[eventStartDateArgument] as! NSNumber
            let endDateDateMillisecondsSinceEpoch = arguments[eventEndDateArgument] as! NSNumber
            let startDate = Date (timeIntervalSince1970: startDateMillisecondsSinceEpoch.doubleValue / 1000.0)
            let endDate = Date (timeIntervalSince1970: endDateDateMillisecondsSinceEpoch.doubleValue / 1000.0)
            let title = arguments[self.eventTitleArgument] as! String
            let description = arguments[self.eventDescriptionArgument] as? String
            let location = arguments[self.eventLocationArgument] as? String
            let ekCalendar = self.eventStore.calendar(withIdentifier: calendarId)
            if (ekCalendar == nil) {
                self.finishWithCalendarNotFoundError(result: result, calendarId: calendarId)
                return
            }
            
            if (!(ekCalendar!.allowsContentModifications)) {
                self.finishWithCalendarReadOnlyError(result: result, calendarId: calendarId)
                return
            }
            
            var ekEvent: EKEvent?
            if(eventId == nil) {
                ekEvent = EKEvent.init(eventStore: self.eventStore)
            } else {
                ekEvent = self.eventStore.event(withIdentifier: eventId!)
                if(ekEvent == nil) {
                    self.finishWithEventNotFoundError(result: result, eventId: eventId!)
                    return
                }
            }
            
            ekEvent!.title = title
            ekEvent!.notes = description
            ekEvent!.startDate = startDate
            ekEvent!.endDate = endDate
            ekEvent!.calendar = ekCalendar!
            ekEvent!.location = location
            
            let recurrenceRuleArguments = arguments[recurrenceRuleArgument] as? Dictionary<String, AnyObject>
            if (recurrenceRuleArguments != nil) {
                let recurrenceFrequencyIndex = recurrenceRuleArguments![recurrenceFrequencyArgument] as? NSInteger
                let totalOccurrences = recurrenceRuleArguments![totalOccurrencesArgument] as? NSInteger
                let interval = recurrenceRuleArguments![intervalArgument] as? NSInteger
                var recurrenceInterval = 1
                let endDate = recurrenceRuleArguments![endDateArgument] as? NSNumber
                let namedFrequency = validFrequencyTypes[recurrenceFrequencyIndex!]
                
                var recurrenceEnd:EKRecurrenceEnd?
                if(endDate != nil) {
                    recurrenceEnd = EKRecurrenceEnd(end: Date.init(timeIntervalSince1970: endDate!.doubleValue / 1000))
                } else if(totalOccurrences != nil && totalOccurrences! > 0) {
                    recurrenceEnd = EKRecurrenceEnd(occurrenceCount: totalOccurrences!)
                }
                
                if(interval != nil && interval! > 1) {
                    recurrenceInterval = interval!
                }
                
                ekEvent!.recurrenceRules = [EKRecurrenceRule(recurrenceWith: namedFrequency, interval: recurrenceInterval, end: recurrenceEnd)]
            } else {
                ekEvent!.recurrenceRules = nil
            }
            
            do {
                try self.eventStore.save(ekEvent!, span: .futureEvents)
                result(ekEvent!.eventIdentifier)
            } catch {
                self.eventStore.reset()
                result(FlutterError(code: self.genericError, message: error.localizedDescription, details: nil))
            }
        }, result: result)
    }
    
    private func deleteEvent(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        checkPermissionsThenExecute(permissionsGrantedAction: {
            let arguments = call.arguments as! Dictionary<String, AnyObject>
            let calendarId = arguments[calendarIdArgument] as! String
            let eventId = arguments[eventIdArgument] as! String
            let ekCalendar = self.eventStore.calendar(withIdentifier: calendarId)
            if (ekCalendar == nil) {
                self.finishWithCalendarNotFoundError(result: result, calendarId: calendarId)
                return
            }
            
            if (!(ekCalendar!.allowsContentModifications)) {
                self.finishWithCalendarReadOnlyError(result: result, calendarId: calendarId)
                return
            }
            
            let ekEvent = self.eventStore.event(withIdentifier: eventId)
            if (ekEvent == nil) {
                self.finishWithEventNotFoundError(result: result, eventId: eventId)
                return
            }
            
            do {
                try self.eventStore.remove(ekEvent!, span: .futureEvents)
                result(true)
            } catch {
                self.eventStore.reset()
                result(FlutterError(code: self.genericError, message: error.localizedDescription, details: nil))
            }
        }, result: result)
    }
    
    private func finishWithUnauthorizedError(result: @escaping FlutterResult) {
        result(FlutterError(code:self.unauthorizedErrorCode, message: self.unauthorizedErrorMessage, details: nil))
    }
    
    private func finishWithCalendarNotFoundError(result: @escaping FlutterResult, calendarId: String) {
        let errorMessage = String(format: self.calendarNotFoundErrorMessageFormat, calendarId)
        result(FlutterError(code:self.notFoundErrorCode, message: errorMessage, details: nil))
    }
    
    private func finishWithCalendarReadOnlyError(result: @escaping FlutterResult, calendarId: String) {
        let errorMessage = String(format: self.calendarReadOnlyErrorMessageFormat, calendarId)
        result(FlutterError(code:self.notAllowed, message: errorMessage, details: nil))
    }
    
    private func finishWithEventNotFoundError(result: @escaping FlutterResult, eventId: String) {
        let errorMessage = String(format: self.eventNotFoundErrorMessageFormat, eventId)
        result(FlutterError(code:self.notFoundErrorCode, message: errorMessage, details: nil))
    }
    
    
    private func encodeJsonAndFinish<T: Codable>(codable: T, result: @escaping FlutterResult) {
        do {
            let jsonEncoder = JSONEncoder()
            let jsonData = try jsonEncoder.encode(codable)
            let jsonString = String(data: jsonData, encoding: .utf8)
            result(jsonString)
        } catch {
            result(FlutterError(code: genericError, message: error.localizedDescription, details: nil))
        }
    }
    
    private func checkPermissionsThenExecute(permissionsGrantedAction: () -> Void, result: @escaping FlutterResult) {
        if(hasPermissions()) {
            permissionsGrantedAction()
            return
        }
        self.finishWithUnauthorizedError(result: result)
    }
    
    private func requestPermissions(completion: @escaping (Bool) -> Void) {
        if(hasPermissions()) {
            completion(true)
            return
        }
        eventStore.requestAccess(to: .event, completion: {
            (accessGranted: Bool, error: Error?) in
            completion(accessGranted)
        })
    }
    
    private func hasPermissions() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == EKAuthorizationStatus.authorized
    }
    
    private func requestPermissions(_ result: @escaping FlutterResult) {
        if(hasPermissions()) {
            result(true)
        }
        eventStore.requestAccess(to: .event, completion: {
            (accessGranted: Bool, error: Error?) in
            result(accessGranted)
        })
    }
}
