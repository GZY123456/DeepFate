import CoreData
import Foundation

final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [UserProfile] = []
    @Published var activeProfileID: UUID?

    private let activeProfileKey = "activeProfileID"

    private let container: NSPersistentContainer
    private let context: NSManagedObjectContext
    private let syncClient = ProfileSyncClient()

    init() {
        let model = NSManagedObjectModel()

        let entity = NSEntityDescription()
        entity.name = "ProfileEntity"
        entity.managedObjectClassName = "NSManagedObject"

        let idAttribute = NSAttributeDescription()
        idAttribute.name = "id"
        idAttribute.attributeType = .stringAttributeType
        idAttribute.isOptional = false

        let payloadAttribute = NSAttributeDescription()
        payloadAttribute.name = "payload"
        payloadAttribute.attributeType = .binaryDataAttributeType
        payloadAttribute.isOptional = false

        let createdAtAttribute = NSAttributeDescription()
        createdAtAttribute.name = "createdAt"
        createdAtAttribute.attributeType = .dateAttributeType
        createdAtAttribute.isOptional = false

        entity.properties = [idAttribute, payloadAttribute, createdAtAttribute]
        model.entities = [entity]

        container = NSPersistentContainer(name: "ProfileStore", managedObjectModel: model)
        container.loadPersistentStores { _, error in
            if let error {
                print("ProfileStore load error: \(error)")
            }
        }
        context = container.viewContext

        loadProfiles()
        restoreActiveProfile()
    }

    func add(_ profile: UserProfile) {
        guard let entity = NSEntityDescription.entity(forEntityName: "ProfileEntity", in: context) else { return }
        let object = NSManagedObject(entity: entity, insertInto: context)
        object.setValue(profile.id.uuidString, forKey: "id")
        object.setValue(profile.createdAt, forKey: "createdAt")
        if let payload = try? JSONEncoder().encode(profile) {
            object.setValue(payload, forKey: "payload")
        }
        saveContext()
        profiles.insert(profile, at: 0)
        if activeProfileID == nil {
            setActive(profile.id)
        }
        syncClient.upsert(profile)
    }

    func update(_ profile: UserProfile) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ProfileEntity")
        request.predicate = NSPredicate(format: "id == %@", profile.id.uuidString)
        request.fetchLimit = 1
        do {
            if let object = try context.fetch(request).first {
                if let payload = try? JSONEncoder().encode(profile) {
                    object.setValue(payload, forKey: "payload")
                }
                object.setValue(profile.createdAt, forKey: "createdAt")
                saveContext()
            }
        } catch {
            print("ProfileStore update error: \(error)")
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        }
        syncClient.upsert(profile)
    }

    func delete(id: UUID) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ProfileEntity")
        request.predicate = NSPredicate(format: "id == %@", id.uuidString)
        do {
            let results = try context.fetch(request)
            results.forEach { context.delete($0) }
            saveContext()
        } catch {
            print("ProfileStore delete error: \(error)")
        }
        profiles.removeAll { $0.id == id }
        if activeProfileID == id {
            let next = profiles.first?.id
            setActive(next)
        }
        syncClient.delete(id: id)
    }

    func refresh() {
        loadProfiles()
    }

    func setActive(_ id: UUID?, shouldSync: Bool = true) {
        activeProfileID = id
        let value = id?.uuidString ?? ""
        UserDefaults.standard.set(value, forKey: activeProfileKey)
        if shouldSync,
           let id,
           let profile = profiles.first(where: { $0.id == id }) {
            syncClient.upsert(profile)
        }
    }

    func syncFromRemote(_ remoteProfiles: [UserProfile], preferredActiveId: UUID?) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ProfileEntity")
        do {
            let results = try context.fetch(request)
            results.forEach { context.delete($0) }
            saveContext()
        } catch {
            print("ProfileStore clear error: \(error)")
        }

        for profile in remoteProfiles {
            guard let entity = NSEntityDescription.entity(forEntityName: "ProfileEntity", in: context) else { continue }
            let object = NSManagedObject(entity: entity, insertInto: context)
            object.setValue(profile.id.uuidString, forKey: "id")
            object.setValue(profile.createdAt, forKey: "createdAt")
            if let payload = try? JSONEncoder().encode(profile) {
                object.setValue(payload, forKey: "payload")
            }
        }
        saveContext()
        profiles = remoteProfiles

        if let preferredActiveId, remoteProfiles.contains(where: { $0.id == preferredActiveId }) {
            setActive(preferredActiveId, shouldSync: false)
        } else if let existing = activeProfileID, remoteProfiles.contains(where: { $0.id == existing }) {
            setActive(existing, shouldSync: false)
        } else {
            setActive(remoteProfiles.first?.id, shouldSync: false)
        }
    }

    private func loadProfiles() {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ProfileEntity")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let results = try context.fetch(request)
            let decoded = results.compactMap { object -> UserProfile? in
                guard let payload = object.value(forKey: "payload") as? Data else { return nil }
                return try? JSONDecoder().decode(UserProfile.self, from: payload)
            }
            profiles = decoded
            if activeProfileID == nil {
                activeProfileID = profiles.first?.id
            }
        } catch {
            print("ProfileStore fetch error: \(error)")
            profiles = []
        }
    }

    private func restoreActiveProfile() {
        let stored = UserDefaults.standard.string(forKey: activeProfileKey) ?? ""
        if let id = UUID(uuidString: stored) {
            activeProfileID = id
        }
    }

    private func saveContext() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            print("ProfileStore save error: \(error)")
        }
    }
}
