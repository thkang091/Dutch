import SwiftUI
import Contacts
import ContactsUI

// MARK: - Dutch Custom Icons

/// Two standing figures — circle head, trapezoidal body, shared ground line.
/// Filled = active, outlined = inactive.
struct GroupIcon: View {
    var size: CGFloat = 22
    var filled: Bool = false
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let strokeW: CGFloat = 1.5

            func drawFigure(cx: CGFloat, headY: CGFloat, scale: CGFloat) {
                // Head
                let headR = w * 0.115 * scale
                let headRect = CGRect(x: cx - headR, y: headY, width: headR * 2, height: headR * 2)
                var headPath = Path(ellipseIn: headRect)
                if filled {
                    ctx.fill(headPath, with: .color(ink))
                } else {
                    ctx.stroke(headPath, with: .color(ink), lineWidth: strokeW)
                }

                // Body trapezoid
                let bodyTop    = headY + headR * 2 + h * 0.03
                let bodyBottom = h * 0.82
                let bodyTopW   = headR * 1.4 * scale
                let bodyBotW   = headR * 2.0 * scale
                var bodyPath   = Path()
                bodyPath.move(to:    CGPoint(x: cx - bodyTopW, y: bodyTop))
                bodyPath.addLine(to: CGPoint(x: cx + bodyTopW, y: bodyTop))
                bodyPath.addLine(to: CGPoint(x: cx + bodyBotW, y: bodyBottom))
                bodyPath.addLine(to: CGPoint(x: cx - bodyBotW, y: bodyBottom))
                bodyPath.closeSubpath()
                if filled {
                    ctx.fill(bodyPath, with: .color(ink))
                } else {
                    ctx.stroke(bodyPath, with: .color(ink), lineWidth: strokeW)
                }
            }

            // Back-left figure (slightly smaller, offset left)
            drawFigure(cx: w * 0.32, headY: h * 0.08, scale: 0.85)
            // Front-right figure (slightly smaller, offset right)
            drawFigure(cx: w * 0.68, headY: h * 0.08, scale: 0.85)

            // Ground line
            var ground = Path()
            ground.move(to:    CGPoint(x: w * 0.08, y: h * 0.88))
            ground.addLine(to: CGPoint(x: w * 0.92, y: h * 0.88))
            ctx.stroke(ground, with: .color(ink), lineWidth: strokeW)
        }
        .frame(width: size, height: size)
    }
}

/// Single standing figure — circle head, trapezoid body.
struct PersonIcon: View {
    var size: CGFloat = 20
    var filled: Bool = false
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5
            let cx = w / 2

            // Head
            let headR = w * 0.18
            let headY = h * 0.06
            let headRect = CGRect(x: cx - headR, y: headY, width: headR * 2, height: headR * 2)
            let headPath = Path(ellipseIn: headRect)
            if filled {
                ctx.fill(headPath, with: .color(ink))
            } else {
                ctx.stroke(headPath, with: .color(ink), lineWidth: sw)
            }

            // Body
            let bodyTop    = headY + headR * 2 + h * 0.04
            let bodyBottom = h * 0.88
            let topW       = headR * 1.3
            let botW       = headR * 2.0
            var body = Path()
            body.move(to:    CGPoint(x: cx - topW, y: bodyTop))
            body.addLine(to: CGPoint(x: cx + topW, y: bodyTop))
            body.addLine(to: CGPoint(x: cx + botW, y: bodyBottom))
            body.addLine(to: CGPoint(x: cx - botW, y: bodyBottom))
            body.closeSubpath()
            if filled {
                ctx.fill(body, with: .color(ink))
            } else {
                ctx.stroke(body, with: .color(ink), lineWidth: sw)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Clock icon — circle outline, two hands (hour short, minute long).
struct ClockIcon: View {
    var size: CGFloat = 20
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5
            let cx = w / 2, cy = h / 2
            let r  = min(w, h) / 2 - sw

            // Outer ring
            let ring = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            ctx.stroke(ring, with: .color(ink), lineWidth: sw)

            // Minute hand (pointing up-right ~12:10)
            var min = Path()
            min.move(to: CGPoint(x: cx, y: cy))
            min.addLine(to: CGPoint(x: cx + r * 0.35, y: cy - r * 0.55))
            ctx.stroke(min, with: .color(ink), lineWidth: sw)

            // Hour hand (pointing up ~12:00)
            var hour = Path()
            hour.move(to: CGPoint(x: cx, y: cy))
            hour.addLine(to: CGPoint(x: cx, y: cy - r * 0.5))
            ctx.stroke(hour, with: .color(ink), lineWidth: sw)

            // Center dot
            let dot = Path(ellipseIn: CGRect(x: cx - 1.5, y: cy - 1.5, width: 3, height: 3))
            ctx.fill(dot, with: .color(ink))
        }
        .frame(width: size, height: size)
    }
}

/// Chevron pointing right.
struct ChevronRightIcon: View {
    var size: CGFloat = 14
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            var p = Path()
            p.move(to:    CGPoint(x: w * 0.3, y: h * 0.2))
            p.addLine(to: CGPoint(x: w * 0.7, y: h * 0.5))
            p.addLine(to: CGPoint(x: w * 0.3, y: h * 0.8))
            ctx.stroke(p, with: .color(ink.opacity(0.5)), lineWidth: 1.5)
        }
        .frame(width: size, height: size)
    }
}

/// Chevron pointing left.
struct ChevronLeftIcon: View {
    var size: CGFloat = 18
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            var p = Path()
            p.move(to:    CGPoint(x: w * 0.65, y: h * 0.2))
            p.addLine(to: CGPoint(x: w * 0.3,  y: h * 0.5))
            p.addLine(to: CGPoint(x: w * 0.65, y: h * 0.8))
            ctx.stroke(p, with: .color(ink), lineWidth: 1.8)
        }
        .frame(width: size, height: size)
    }
}

/// Chevron pointing up.
struct ChevronUpIcon: View {
    var size: CGFloat = 14
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            var p = Path()
            p.move(to:    CGPoint(x: w * 0.2, y: h * 0.65))
            p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.3))
            p.addLine(to: CGPoint(x: w * 0.8, y: h * 0.65))
            ctx.stroke(p, with: .color(ink.opacity(0.5)), lineWidth: 1.5)
        }
        .frame(width: size, height: size)
    }
}

/// Chevron pointing down.
struct ChevronDownIcon: View {
    var size: CGFloat = 14
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            var p = Path()
            p.move(to:    CGPoint(x: w * 0.2, y: h * 0.35))
            p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.7))
            p.addLine(to: CGPoint(x: w * 0.8, y: h * 0.35))
            ctx.stroke(p, with: .color(ink.opacity(0.5)), lineWidth: 1.5)
        }
        .frame(width: size, height: size)
    }
}

/// Plus symbol — two perpendicular bars.
struct PlusIcon: View {
    var size: CGFloat = 20
    var color: Color = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 2.0
            var horiz = Path()
            horiz.move(to:    CGPoint(x: w * 0.2, y: h * 0.5))
            horiz.addLine(to: CGPoint(x: w * 0.8, y: h * 0.5))
            ctx.stroke(horiz, with: .color(color), lineWidth: sw)

            var vert = Path()
            vert.move(to:    CGPoint(x: w * 0.5, y: h * 0.2))
            vert.addLine(to: CGPoint(x: w * 0.5, y: h * 0.8))
            ctx.stroke(vert, with: .color(color), lineWidth: sw)
        }
        .frame(width: size, height: size)
    }
}

/// X / close icon — two diagonal lines crossing.
struct XMarkIcon: View {
    var size: CGFloat = 14
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5
            let pad: CGFloat = 0.22
            var d1 = Path()
            d1.move(to:    CGPoint(x: w * pad,       y: h * pad))
            d1.addLine(to: CGPoint(x: w * (1 - pad), y: h * (1 - pad)))
            ctx.stroke(d1, with: .color(ink.opacity(0.5)), lineWidth: sw)

            var d2 = Path()
            d2.move(to:    CGPoint(x: w * (1 - pad), y: h * pad))
            d2.addLine(to: CGPoint(x: w * pad,       y: h * (1 - pad)))
            ctx.stroke(d2, with: .color(ink.opacity(0.5)), lineWidth: sw)
        }
        .frame(width: size, height: size)
    }
}

/// Arrow pointing right — horizontal shaft + arrowhead.
struct ArrowRightIcon: View {
    var size: CGFloat = 16
    var color: Color = .white

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.8
            // Shaft
            var shaft = Path()
            shaft.move(to:    CGPoint(x: w * 0.12, y: h * 0.5))
            shaft.addLine(to: CGPoint(x: w * 0.78, y: h * 0.5))
            ctx.stroke(shaft, with: .color(color), lineWidth: sw)
            // Head
            var head = Path()
            head.move(to:    CGPoint(x: w * 0.55, y: h * 0.22))
            head.addLine(to: CGPoint(x: w * 0.88, y: h * 0.5))
            head.addLine(to: CGPoint(x: w * 0.55, y: h * 0.78))
            ctx.stroke(head, with: .color(color), lineWidth: sw)
        }
        .frame(width: size, height: size)
    }
}

/// Three horizontal lines at different lengths (ellipsis / more options).
struct EllipsisIcon: View {
    var size: CGFloat = 16
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let r: CGFloat = w * 0.09
            let cy = h / 2
            let positions: [CGFloat] = [w * 0.22, w * 0.5, w * 0.78]
            for cx in positions {
                let dot = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                ctx.fill(dot, with: .color(ink.opacity(0.5)))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Phone receiver — small rectangle outline with a diagonal notch.
struct PhoneIcon: View {
    var size: CGFloat = 12
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5
            // Simplified: tall rounded rect + small line for earpiece
            let rect = CGRect(x: w * 0.2, y: h * 0.08, width: w * 0.6, height: h * 0.84)
            var body = Path(roundedRect: rect, cornerRadius: 2)
            ctx.stroke(body, with: .color(ink.opacity(0.5)), lineWidth: sw)
            // Earpiece bar
            var ear = Path()
            ear.move(to:    CGPoint(x: w * 0.38, y: h * 0.18))
            ear.addLine(to: CGPoint(x: w * 0.62, y: h * 0.18))
            ctx.stroke(ear, with: .color(ink.opacity(0.5)), lineWidth: sw)
        }
        .frame(width: size, height: size)
    }
}

/// Checkmark circle — filled circle + white checkmark inside (for ADDED badge).
struct CheckmarkCircleIcon: View {
    var size: CGFloat = 14
    var color: Color = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            // Filled circle
            let circle = Path(ellipseIn: CGRect(x: 1, y: 1, width: w - 2, height: h - 2))
            ctx.fill(circle, with: .color(color))
            // Checkmark
            var check = Path()
            check.move(to:    CGPoint(x: w * 0.28, y: h * 0.52))
            check.addLine(to: CGPoint(x: w * 0.45, y: h * 0.68))
            check.addLine(to: CGPoint(x: w * 0.72, y: h * 0.35))
            ctx.stroke(check, with: .color(.white), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

/// Magnifying glass — circle + angled handle line.
struct MagnifyingGlassIcon: View {
    var size: CGFloat = 18
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5
            let r = min(w, h) * 0.3
            let cx = w * 0.4, cy = h * 0.4
            let lens = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            ctx.stroke(lens, with: .color(ink.opacity(0.6)), lineWidth: sw)
            var handle = Path()
            handle.move(to:    CGPoint(x: cx + r * 0.7, y: cy + r * 0.7))
            handle.addLine(to: CGPoint(x: w * 0.85,     y: h * 0.85))
            ctx.stroke(handle, with: .color(ink.opacity(0.6)), lineWidth: sw)
        }
        .frame(width: size, height: size)
    }
}

/// X inside a circle — used for "clear search".
struct XCircleIcon: View {
    var size: CGFloat = 18
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5
            let circle = Path(ellipseIn: CGRect(x: 1, y: 1, width: w - 2, height: h - 2))
            ctx.stroke(circle, with: .color(ink.opacity(0.4)), lineWidth: sw)
            let pad: CGFloat = 0.3
            var d1 = Path()
            d1.move(to:    CGPoint(x: w * pad,       y: h * pad))
            d1.addLine(to: CGPoint(x: w * (1 - pad), y: h * (1 - pad)))
            ctx.stroke(d1, with: .color(ink.opacity(0.4)), lineWidth: sw)
            var d2 = Path()
            d2.move(to:    CGPoint(x: w * (1 - pad), y: h * pad))
            d2.addLine(to: CGPoint(x: w * pad,       y: h * (1 - pad)))
            ctx.stroke(d2, with: .color(ink.opacity(0.4)), lineWidth: sw)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Persistence Manager

class PeopleStorageManager {
    static let shared = PeopleStorageManager()

    private let recentPeopleKey = "recentPeople_v1"
    private let savedGroupsKey  = "savedGroups_v1"

    private init() {}

    func loadRecentPeople() -> [RecentPerson] {
        guard let data = UserDefaults.standard.data(forKey: recentPeopleKey),
              let decoded = try? JSONDecoder().decode([RecentPerson].self, from: data) else { return [] }
        return decoded
    }

    func addRecentPerson(_ person: RecentPerson) {
        var recent = loadRecentPeople()
        recent.removeAll { $0.name == person.name }
        recent.insert(person, at: 0)
        recent = Array(recent.prefix(5))
        if let encoded = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(encoded, forKey: recentPeopleKey)
        }
    }

    func loadSavedGroups() -> [PersistedGroup] {
        guard let data = UserDefaults.standard.data(forKey: savedGroupsKey),
              let decoded = try? JSONDecoder().decode([PersistedGroup].self, from: data) else { return [] }
        return decoded
    }

    func saveGroup(_ group: PersistedGroup) {
        var groups = loadSavedGroups()
        groups.removeAll { $0.id == group.id }
        groups.insert(group, at: 0)
        groups = Array(groups.prefix(5))
        if let encoded = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(encoded, forKey: savedGroupsKey)
        }
    }

    func deleteGroup(id: String) {
        var groups = loadSavedGroups()
        groups.removeAll { $0.id == id }
        if let encoded = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(encoded, forKey: savedGroupsKey)
        }
    }

    func updateGroupLastUsed(id: String) {
        var groups = loadSavedGroups()
        if let index = groups.firstIndex(where: { $0.id == id }) {
            groups[index].lastUsed = Date()
            groups = groups.sorted { $0.lastUsed > $1.lastUsed }
            groups = Array(groups.prefix(5))
            if let encoded = try? JSONEncoder().encode(groups) {
                UserDefaults.standard.set(encoded, forKey: savedGroupsKey)
            }
        }
    }
}

// MARK: - Models

struct RecentPerson: Codable, Identifiable {
    var id: String { name }
    let name: String
    let phoneNumber: String?
    let imageData: Data?
    var lastUsed: Date

    init(name: String, phoneNumber: String? = nil, imageData: Data? = nil) {
        self.name        = name
        self.phoneNumber = phoneNumber
        self.imageData   = imageData
        self.lastUsed    = Date()
    }
}

struct PersistedGroupMember: Codable, Identifiable {
    var id: String { name }
    let name: String
    let phoneNumber: String?
    let imageData: Data?
}

struct PersistedGroup: Codable, Identifiable {
    let id: String
    var name: String
    var members: [PersistedGroupMember]
    var lastUsed: Date

    init(id: String = UUID().uuidString, name: String, members: [PersistedGroupMember]) {
        self.id       = id
        self.name     = name
        self.members  = members
        self.lastUsed = Date()
    }

    var memberNames: [String] { members.map(\.name) }
}

// MARK: - GroupRow

struct GroupRow: View {
    let group: PersistedGroup
    let onActivate: () -> Void
    let onDelete: () -> Void

    @State private var showingDeleteConfirm = false
    
    private let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)
    private let chalk = Color(red: 0.96, green: 0.96, blue: 0.94)
    private let cardRadius: CGFloat = 8

    var body: some View {
        Button(action: {
            HapticManager.impact(style: .medium)
            onActivate()
        }) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 36, height: 36)
                    // Custom group/people icon
                    GroupIcon(size: 18, filled: false)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(ink)
                    Text("\(group.members.count) people")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: -8) {
                    ForEach(Array(group.members.prefix(3).enumerated()), id: \.element.id) { index, member in
                        AvatarView(
                            imageData: member.imageData,
                            initials: String(member.name.prefix(2).uppercased()),
                            size: 28
                        )
                        .overlay(Circle().stroke(ivory, lineWidth: 2))
                        .zIndex(Double(3 - index))
                    }
                }

                Button(action: {
                    HapticManager.notification(type: .warning)
                    showingDeleteConfirm = true
                }) {
                    // Custom ellipsis (three dots)
                    EllipsisIcon(size: 20)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
        .alert("Remove Group", isPresented: $showingDeleteConfirm) {
            Button("Remove", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove \"\(group.name)\" from your quick groups?")
        }
    }
}

// MARK: - GroupNameSheet

struct GroupNameSheet: View {
    @Binding var isPresented: Bool
    let onConfirm: (String) -> Void
    
    @State private var groupName = ""
    @Environment(\.colorScheme) var colorScheme
    
    private let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)
    
    var body: some View {
        NavigationView {
            ZStack {
                ivory.ignoresSafeArea()
                
                VStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Name Your Group")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(ink)
                        
                        Text("Give this group a memorable name")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    TextField("Enter group name", text: $groupName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(ink)
                        .padding(14)
                        .background(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(ink.opacity(0.15), lineWidth: 1)
                        )
                        .cornerRadius(2)
                        .submitLabel(.done)
                        .onSubmit {
                            if !groupName.isEmpty {
                                confirmName()
                            }
                        }
                    
                    Spacer()
                    
                    Button(action: confirmName) {
                        HStack(spacing: 6) {
                            Text("Start Group Mode")
                                .font(.system(size: 16, weight: .bold))
                            // Custom arrow right icon
                            ArrowRightIcon(size: 16, color: groupName.isEmpty ? Color.secondary : .white)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(groupName.isEmpty ? Color.secondary.opacity(0.3) : ink)
                        .cornerRadius(2)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(groupName.isEmpty)
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .foregroundColor(ink)
                }
            }
        }
    }
    
    private func confirmName() {
        guard !groupName.isEmpty else { return }
        HapticManager.impact(style: .medium)
        onConfirm(groupName)
        isPresented = false
    }
}

// MARK: - PeopleView

struct PeopleView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var router: Router
    @EnvironmentObject var tutorialManager: TutorialManager
    @Environment(\.colorScheme) var colorScheme

    @StateObject private var groupManager = GroupManager.shared

    @State private var newPersonName = ""
    @State private var showContactPicker = false
    @State private var showSaveGroupDialog = false
    @State private var groupName = ""
    @State private var recentPeople: [RecentPerson] = []
    @State private var savedGroups: [PersistedGroup] = []
    @State private var recentPeopleExpanded = false
    @State private var savedGroupsExpanded = false
    @State private var showGroupModeNameSheet = false
    @State private var pendingGroupName = ""
    @State private var pendingGroupMembers: [GroupMember] = []
    @State private var cachedSplitTotal: Double = 0
    @FocusState private var isNameFieldFocused: Bool

    private let storage = PeopleStorageManager.shared
    private let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)
    private let chalk = Color(red: 0.96, green: 0.96, blue: 0.94)
    private let cardRadius: CGFloat = 8

    private var shouldHighlightContactButton: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .peopleAddContact
    }
    private var shouldHighlightPeopleList: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .peopleList
    }
    private var shouldHighlightContinue: Bool {
        tutorialManager.isActive && tutorialManager.currentStep?.targetView == .continueButton
    }

    var addedPeopleCount: Int {
        appState.people.filter { !$0.isCurrentUser }.count
    }

    private var canContinue: Bool {
        appState.people.count > 1
    }

    private var splitTotal: Double {
        cachedSplitTotal
    }

    private var splitSubtitle: String {
        if canContinue {
            return "\(appState.people.count) included" + (splitTotal > 0 ? " · \(currencyString(splitTotal))" : "")
        }
        return "Add one person to continue"
    }

    var body: some View {
        ZStack {
            ivory.ignoresSafeArea()

            VStack(spacing: 0) {
                headerSection

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        splitSummaryCard
                        addPeopleSection

                        if addedPeopleCount > 0 {
                            sectionDivider
                            peopleListSection
                        }

                        if !recentPeople.isEmpty {
                            sectionDivider
                            recentPeopleSection
                        }

                        if !savedGroups.isEmpty {
                            sectionDivider
                            savedGroupsSection
                        }
                    }
                    .padding(.bottom, 120)
                }
                .disabled(tutorialManager.isActive)

                bottomCTA
            }

            if tutorialManager.isActive {
                TutorialOverlay(context: .people).zIndex(200)
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            appState.ensureCurrentUser()
            refreshSplitTotalCache()
            clearSessionPeople()
            loadPersistedData()
            if !appState.forcePersonalSplitForCurrentUpload, groupManager.isGroupModeEnabled {
                GroupManager.shared.syncMembersToAppState(appState)
            }

            if tutorialManager.isActive && !tutorialManager.isCurrentStep(in: .people) {
                withAnimation { tutorialManager.currentStepIndex = 3 }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .groupDidLeave)) { _ in
            let currentUser = appState.people.first(where: { $0.isCurrentUser })
                ?? Person(name: appState.profile.name, isCurrentUser: true)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                appState.people = [currentUser]
            }
            recentPeople = storage.loadRecentPeople()
            savedGroups = storage.loadSavedGroups()
        }
        .onChange(of: appState.transactions.count) { _, _ in
            refreshSplitTotalCache()
        }
        .sheet(isPresented: $showGroupModeNameSheet) {
            GroupNameSheet(isPresented: $showGroupModeNameSheet) { confirmedName in
                launchGroupMode(name: confirmedName, members: pendingGroupMembers)
            }
        }
        .alert("Save Group", isPresented: $showSaveGroupDialog) {
            TextField("Group name (e.g., Weekend Crew)", text: $groupName)
            Button("Save") {
                if !groupName.isEmpty {
                    saveCurrentGroup()
                    groupName = ""
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save this group for quick access later")
        }
    }

    // MARK: - Group Mode Launch

    private func launchGroupMode(name: String, members: [GroupMember]) {
        appState.forcePersonalSplitForCurrentUpload = false
        let currentUser = appState.people.first(where: { $0.isCurrentUser })
        var people: [Person] = [currentUser].compactMap { $0 }
        for m in members where !m.isCurrentUser {
            if !people.contains(where: { $0.name == m.name }) {
                people.append(m.toPerson())
            }
        }
        appState.people = people

        groupManager.createFreshGroup(name: name, members: members)
        groupManager.syncMembersToAppState(appState)

        HapticManager.notification(type: .success)
    }

    // MARK: - Session & Persistence

    private func clearSessionPeople() {
        guard !tutorialManager.isActive else { return }
        if !appState.forcePersonalSplitForCurrentUpload, groupManager.isGroupModeEnabled {
            groupManager.syncMembersToAppState(appState)
        } else {
            let currentUser = appState.people.first(where: { $0.isCurrentUser })
            appState.people = [currentUser].compactMap { $0 }
        }
    }

    private func loadPersistedData() {
        recentPeople = storage.loadRecentPeople()
        savedGroups = storage.loadSavedGroups()
    }

    private func refreshSplitTotalCache() {
        cachedSplitTotal = appState.transactions.reduce(0) { $0 + $1.amount }
    }

    private func saveCurrentGroup() {
        let nonUserPeople = appState.people.filter { !$0.isCurrentUser }
        guard !nonUserPeople.isEmpty else { return }
        let members = nonUserPeople.map {
            PersistedGroupMember(name: $0.name, phoneNumber: $0.phoneNumber, imageData: $0.contactImage)
        }
        let group = PersistedGroup(name: groupName, members: members)
        storage.saveGroup(group)
        savedGroups = storage.loadSavedGroups()
        appState.saveGroup(name: groupName)
    }

    private func recordRecentPeople(from people: [Person]) {
        for person in people where !person.isCurrentUser {
            LocalContactNameStore.save(name: person.name, phoneNumber: person.phoneNumber, imageData: person.contactImage)
            storage.addRecentPerson(RecentPerson(name: person.name, phoneNumber: person.phoneNumber, imageData: person.contactImage))
        }
        recentPeople = storage.loadRecentPeople()
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button(action: {
                    HapticManager.impact(style: .light)
                    router.navigateBack()
                }) {
                    ZStack {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: 40, height: 40)
                        // Custom chevron left icon
                        ChevronLeftIcon(size: 18)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(tutorialManager.isActive)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Who's Splitting?")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(ink)
                    Text(splitSubtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    HapticManager.impact(style: .light)
                    router.presentProfile()
                }) {
                    AvatarView(
                        imageData: appState.profile.avatarImage,
                        initials: appState.profile.initials,
                        size: 40
                    )
                    .overlay(Circle().stroke(ink, lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(tutorialManager.isActive)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .background(ivory)

            Rectangle()
                .fill(ink.opacity(0.85))
                .frame(height: 1)
                .padding(.horizontal, 20)
        }
    }

    private var splitSummaryCard: some View {
        HStack(spacing: 12) {
            summaryMetric(
                title: "TOTAL",
                value: splitTotal > 0 ? currencyString(splitTotal) : "--"
            )

            Rectangle()
                .fill(ink.opacity(0.16))
                .frame(width: 1, height: 36)

            summaryMetric(
                title: "PEOPLE",
                value: "\(appState.people.count)"
            )

            Rectangle()
                .fill(ink.opacity(0.16))
                .frame(width: 1, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(canContinue ? "READY" : "NEEDS 1 MORE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(canContinue ? Color(red: 0.18, green: 0.50, blue: 0.32) : ink.opacity(0.55))
                    .tracking(1)
                Text(canContinue ? "Split can start" : "Add someone")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ink.opacity(0.70))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(chalk)
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(ink.opacity(0.22), lineWidth: 1.5)
        )
        .cornerRadius(cardRadius)
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private func summaryMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(1)
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(minWidth: 68, alignment: .leading)
    }

    // MARK: - Section Divider
    
    private var sectionDivider: some View {
        Rectangle()
            .fill(ink.opacity(0.2))
            .frame(height: 1)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
    }

    // MARK: - Add People Section

    private var addPeopleSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 10) {
                currentUserRow
                addPersonInput
                contactPickerButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 16)
        }
    }

    private var currentUserRow: some View {
        HStack(spacing: 12) {
            AvatarView(
                imageData: appState.profile.avatarImage,
                initials: appState.profile.initials,
                size: 44
            )
            .overlay(Circle().stroke(ink, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.profile.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(ink)
                Text("You")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 5) {
                CheckmarkCircleIcon(size: 12, color: ink)
                Text("ADDED")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
            }
            .foregroundColor(ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(ivory)
            .overlay(
                RoundedRectangle(cornerRadius: cardRadius)
                    .stroke(ink.opacity(0.18), lineWidth: 1)
            )
            .cornerRadius(cardRadius)
        }
        .padding(14)
        .background(chalk)
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(ink, lineWidth: 1.5)
        )
        .cornerRadius(cardRadius)
    }

    private var addPersonInput: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(ink.opacity(0.1))
                        .frame(width: 24, height: 24)
                    // Custom single person icon (filled = input has focus context)
                    PersonIcon(size: 13, filled: true)
                }
                
                TextField("Enter name", text: $newPersonName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(ink)
                    .submitLabel(.done)
                    .focused($isNameFieldFocused)
                    .disabled(tutorialManager.isActive)
                    .onSubmit { if !newPersonName.isEmpty { addPerson() } }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .overlay(
                Rectangle()
                    .fill(ink.opacity(0.15))
                    .frame(width: 1)
                , alignment: .trailing
            )

            Button(action: {
                HapticManager.impact(style: .medium)
                addPerson()
            }) {
                // Custom plus icon
                PlusIcon(size: 20, color: newPersonName.isEmpty ? Color.secondary : .white)
                    .frame(width: 56, height: 56)
                    .background(newPersonName.isEmpty ? Color.white : ink)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(newPersonName.isEmpty || tutorialManager.isActive)
        }
        .frame(height: 56)
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(ink, lineWidth: 1.5)
        )
        .cornerRadius(cardRadius)
    }

    private var contactPickerButton: some View {
        Button(action: {
            HapticManager.impact(style: .light)
            dismissKeyboard()
            showContactPicker = true
        }) {
            HStack(spacing: 10) {
                Text("Add from Contacts")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(ink)
                Spacer()
                // Custom chevron right icon
                ChevronRightIcon(size: 14)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(chalk)
            .overlay(
                RoundedRectangle(cornerRadius: cardRadius)
                    .stroke(ink, lineWidth: 1.5)
            )
            .cornerRadius(cardRadius)
        }
        .buttonStyle(PlainButtonStyle())
        .tutorialSpotlight(isHighlighted: shouldHighlightContactButton, cornerRadius: cardRadius)
        .disabled(tutorialManager.isActive)
        .sheet(isPresented: $showContactPicker) {
            SearchableContactPickerView { contacts in
                var newlyAdded: [Person] = []
                for contact in contacts {
                    let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                    if !fullName.isEmpty && !appState.people.contains(where: { $0.name == fullName }) {
                        let phone = contact.phoneNumbers.first?.value.stringValue
                        let imageData = contact.dutchSafeImageData
                        LocalContactNameStore.save(name: fullName, phoneNumber: phone, imageData: imageData)
                        let person = Person(name: fullName, contactImage: imageData, phoneNumber: phone)
                        appState.addPerson(person)
                        hydrateDutchMember(for: person)
                        newlyAdded.append(person)
                    }
                }
                recordRecentPeople(from: newlyAdded)
            }
        }
    }

    // MARK: - Recent People Section

    private var recentPeopleSection: some View {
        VStack(spacing: 0) {
            Button(action: {
                HapticManager.impact(style: .light)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    recentPeopleExpanded.toggle()
                }
            }) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 24, height: 24)
                        // Custom clock icon
                        ClockIcon(size: 14)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recent People")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(ink)
                        Text("\(recentPeople.count) people")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    HStack(spacing: -8) {
                        ForEach(Array(recentPeople.prefix(3).enumerated()), id: \.element.id) { index, person in
                            AvatarView(
                                imageData: person.imageData,
                                initials: String(person.name.prefix(2).uppercased()),
                                size: 28
                            )
                            .overlay(Circle().stroke(ivory, lineWidth: 2))
                            .zIndex(Double(3 - index))
                        }
                    }

                    // Custom chevron up/down
                    if recentPeopleExpanded {
                        ChevronUpIcon(size: 14).padding(.leading, 4)
                    } else {
                        ChevronDownIcon(size: 14).padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(tutorialManager.isActive)

            if recentPeopleExpanded {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(ink.opacity(0.2))
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                    
                    VStack(spacing: 8) {
                        ForEach(recentPeople) { person in
                            let alreadyAdded = appState.people.contains(where: { $0.name == person.name })
                            recentPersonRow(person: person, alreadyAdded: alreadyAdded)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(chalk)
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(ink, lineWidth: 1.5)
        )
        .cornerRadius(cardRadius)
        .padding(.horizontal, 20)
    }

    private func recentPersonRow(person: RecentPerson, alreadyAdded: Bool) -> some View {
        HStack(spacing: 12) {
            AvatarView(
                imageData: person.imageData,
                initials: String(person.name.prefix(2).uppercased()),
                size: 40
            )
            .overlay(Circle().stroke(ink.opacity(0.15), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(ink)
                if let phone = person.phoneNumber, !phone.isEmpty {
                    HStack(spacing: 4) {
                        // Custom phone icon
                        PhoneIcon(size: 10)
                        Text(phone)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
            }

            Spacer()

            if alreadyAdded {
                HStack(spacing: 4) {
                    // Custom checkmark circle icon
                    CheckmarkCircleIcon(size: 13, color: ink)
                    Text("ADDED")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.3)
                }
                .foregroundColor(ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(chalk)
                .overlay(
                    RoundedRectangle(cornerRadius: cardRadius)
                        .stroke(ink.opacity(0.18), lineWidth: 1)
                )
                .cornerRadius(cardRadius)
            } else {
                Button(action: {
                    HapticManager.impact(style: .medium)
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        let newPerson = Person(name: person.name, contactImage: person.imageData, phoneNumber: person.phoneNumber)
                        appState.addPerson(newPerson)
                        hydrateDutchMember(for: newPerson)
                    }
                }) {
                    HStack(spacing: 4) {
                        // Custom plus icon (small)
                        PlusIcon(size: 12, color: .white)
                        Text("ADD")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.3)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(ink)
                    .cornerRadius(cardRadius)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(tutorialManager.isActive)
            }
        }
        .padding(12)
        .background(ivory)
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(ink.opacity(0.1), lineWidth: 1)
        )
        .cornerRadius(cardRadius)
    }

    // MARK: - Added People Section

    private var peopleListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(groupManager.isGroupModeEnabled ? "GROUP MEMBERS" : "ADDED PEOPLE")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .tracking(1.2)
                    Text(groupManager.isGroupModeEnabled ? "Tap × to exclude someone from this split" : "\(addedPeopleCount) added to this split")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.7))
                }

                Spacer()

                if addedPeopleCount > 1 && !groupManager.isGroupModeEnabled {
                    Button(action: {
                        HapticManager.impact(style: .light)
                        clearSessionPeople()
                    }) {
                        Text("CLEAR")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(ink.opacity(0.62))
                            .tracking(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(ink.opacity(0.18), lineWidth: 1)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(tutorialManager.isActive)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            VStack(spacing: 8) {
                ForEach(appState.people.filter { !$0.isCurrentUser }) { person in
                    personRow(person: person)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .tutorialSpotlight(isHighlighted: shouldHighlightPeopleList, cornerRadius: cardRadius)
    }

    private func personRow(person: Person) -> some View {
        HStack(spacing: 12) {
            AvatarView(
                imageData: person.contactImage,
                initials: person.initials,
                size: 44
            )
            .overlay(Circle().stroke(ink, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(ink)
                HStack(spacing: 6) {
                    if person.isDutchMember {
                        Text("Member of Dutch")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.4)
                            .foregroundColor(Color(red: 0.18, green: 0.50, blue: 0.32))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color(red: 0.18, green: 0.50, blue: 0.32).opacity(0.10))
                            .cornerRadius(4)
                    } else if person.phoneNumber != nil {
                        Text("From contacts")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    if person.hasPaymentMethods {
                        Text("Pay ready")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.4)
                            .foregroundColor(ink.opacity(0.60))
                    }
                }
            }

            Spacer()

            Button(action: {
                HapticManager.notification(type: .warning)
                withAnimation(.spring(response: 0.3)) { appState.removePerson(person) }
            }) {
                // Custom X mark icon
                XMarkIcon(size: 14)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(tutorialManager.isActive)
        }
        .padding(14)
        .background(chalk)
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(ink, lineWidth: 1.5)
        )
        .cornerRadius(cardRadius)
    }

    // MARK: - Saved Groups Section

    private var savedGroupsSection: some View {
        VStack(spacing: 0) {
            Button(action: {
                HapticManager.impact(style: .light)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    savedGroupsExpanded.toggle()
                }
            }) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 24, height: 24)
                        // Custom group icon
                        GroupIcon(size: 14, filled: false)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quick Groups")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(ink)
                        Text("\(savedGroups.count) \(savedGroups.count == 1 ? "group" : "groups") saved")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if let firstGroup = savedGroups.first {
                        HStack(spacing: -8) {
                            ForEach(Array(firstGroup.members.prefix(3).enumerated()), id: \.element.id) { index, member in
                                AvatarView(
                                    imageData: member.imageData,
                                    initials: String(member.name.prefix(2).uppercased()),
                                    size: 28
                                )
                                .overlay(Circle().stroke(ivory, lineWidth: 2))
                                .zIndex(Double(3 - index))
                            }
                        }
                    }

                    // Custom chevron up/down
                    if savedGroupsExpanded {
                        ChevronUpIcon(size: 14).padding(.leading, 4)
                    } else {
                        ChevronDownIcon(size: 14).padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(tutorialManager.isActive)

            if savedGroupsExpanded {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(ink.opacity(0.2))
                        .frame(height: 1)
                        .padding(.horizontal, 16)

                    VStack(spacing: 0) {
                        ForEach(Array(savedGroups.enumerated()), id: \.element.id) { index, group in
                            if index > 0 {
                                Rectangle()
                                    .fill(ink.opacity(0.2))
                                    .frame(height: 1)
                                    .padding(.leading, 56)
                            }
                            GroupRow(
                                group: group,
                                onActivate: {
                                    let currentUser = appState.people.first(where: { $0.isCurrentUser })
                                    let toAdd = group.members.map { m -> Person in
                                        let img = m.imageData ?? recentPeople.first(where: { $0.name == m.name })?.imageData
                                        return Person(name: m.name, contactImage: img, phoneNumber: m.phoneNumber)
                                    }
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                        appState.people = [currentUser].compactMap { $0 } + toAdd.filter { !$0.isCurrentUser }
                                    }
                                    storage.updateGroupLastUsed(id: group.id)
                                    savedGroups = storage.loadSavedGroups()
                                    
                                    HapticManager.notification(type: .success)
                                },
                                onDelete: {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                        storage.deleteGroup(id: group.id)
                                        savedGroups = storage.loadSavedGroups()
                                    }
                                }
                            )
                            .disabled(tutorialManager.isActive)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(chalk)
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(ink, lineWidth: 1.5)
        )
        .cornerRadius(cardRadius)
        .padding(.horizontal, 20)
    }

    // MARK: - Bottom CTA

    private var bottomCTA: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(ink.opacity(0.85))
                .frame(height: 1)
                .padding(.horizontal, 20)

            VStack(spacing: 10) {
                if addedPeopleCount > 0 {
                    Button(action: {
                        HapticManager.impact(style: .light)
                        dismissKeyboard()
                        showSaveGroupDialog = true
                    }) {
                        Text("Save as Quick Group")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: cardRadius)
                                    .stroke(ink.opacity(0.2), lineWidth: 1)
                            )
                            .cornerRadius(cardRadius)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(tutorialManager.isActive)
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .opacity
                    ))
                }

                Button(action: {
                    HapticManager.impact(style: .medium)
                    dismissKeyboard()
                    recordRecentPeople(from: appState.people.filter { !$0.isCurrentUser })
                    router.navigateToProcessing()
                }) {
                    HStack(spacing: 6) {
                        Text(canContinue ? "Continue with \(appState.people.count)" : "Add someone to continue")
                            .font(.system(size: 16, weight: .bold))
                        // Custom arrow right icon
                        ArrowRightIcon(size: 16, color: canContinue ? .white : Color.secondary)
                    }
                    .foregroundColor(canContinue ? .white : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(canContinue ? ink : Color.secondary.opacity(0.16))
                    .cornerRadius(cardRadius)
                }
                .buttonStyle(PlainButtonStyle())
                .tutorialSpotlight(isHighlighted: shouldHighlightContinue, cornerRadius: cardRadius)
                .disabled(!canContinue || tutorialManager.isActive)
                .id(appState.people.count)
            }
            .padding(20)
            .background(ivory)
        }
    }

    // MARK: - Helpers

    private func addPerson() {
        guard !newPersonName.isEmpty else { return }
        dismissKeyboard()
        let person = Person(name: newPersonName)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            appState.addPerson(person)
            storage.addRecentPerson(RecentPerson(name: newPersonName))
            recentPeople = storage.loadRecentPeople()
            newPersonName = ""
        }
        hydrateDutchMember(for: person)
    }

    private func dismissKeyboard() {
        isNameFieldFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func currencyString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    private func hydrateDutchMember(for person: Person) {
        AuthManager.shared.lookupVerifiedDutchieUser(phoneNumber: person.phoneNumber, name: person.name) { verified in
            guard let verified,
                  let index = appState.people.firstIndex(where: { $0.id == person.id }) else { return }

            appState.people[index].dutchUID = verified.uid
            appState.people[index].phoneNumber = verified.phoneNumber
            appState.people[index].venmoUsername = verified.venmoUsername
            appState.people[index].venmoLink = verified.venmoLink
            appState.people[index].zelleContact = verified.zelleContact
            appState.people[index].zelleLink = verified.zelleLink

            if appState.people[index].contactImage == nil {
                appState.people[index].contactImage = verified.imageData
            }
            HapticManager.notification(type: .success)
        }
    }
}

// MARK: - Searchable Contact Picker

struct SearchableContactPickerView: View {
    let onContactsSelected: ([CNContact]) -> Void

    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @State private var searchText = ""
    @State private var allContacts: [CNContact] = []
    @State private var selectedContacts: Set<String> = []
    @State private var isLoading = true
    @State private var didRequestContacts = false
    @State private var loadErrorMessage: String?
    
    private let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var filteredContacts: [CNContact] {
        if searchText.isEmpty { return allContacts }
        return allContacts.filter {
            "\($0.givenName) \($0.familyName)".lowercased().contains(searchText.lowercased())
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                ivory.ignoresSafeArea()
                VStack(spacing: 0) {
                    searchBar
                    if isLoading { loadingView }
                    else if let loadErrorMessage { errorStateView(loadErrorMessage) }
                    else if allContacts.isEmpty { emptyStateView }
                    else { contactsList }
                }
            }
            .navigationTitle("Add from Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(.primary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        completeSelection()
                    }
                    .foregroundColor(ink)
                    .fontWeight(.semibold)
                    .disabled(selectedContacts.isEmpty)
                }
            }
        }
        .onAppear { loadContactsIfNeeded() }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            // Custom magnifying glass icon
            MagnifyingGlassIcon(size: 18)
            TextField("Search contacts...", text: $searchText)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.primary)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    // Custom X circle icon
                    XCircleIcon(size: 18)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var contactsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredContacts, id: \.identifier) { contact in
                    contactRow(contact: contact)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleContact(contact) }
                    if contact.identifier != filteredContacts.last?.identifier {
                        Divider().padding(.leading, 72)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func contactRow(contact: CNContact) -> some View {
        let isSelected = selectedContacts.contains(contact.identifier)
        let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)

        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.1)).frame(width: 44, height: 44)
                Text(String(contact.givenName.prefix(1)))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(fullName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                if let phone = contact.phoneNumbers.first?.value.stringValue {
                    Text(phone).font(.system(size: 14)).foregroundColor(.secondary)
                }
            }

            Spacer()

            // Custom selection indicator
            ZStack {
                Circle()
                    .stroke(isSelected ? ink : Color.secondary, lineWidth: 2)
                    .frame(width: 24, height: 24)
                if isSelected {
                    Circle()
                        .fill(ink)
                        .frame(width: 24, height: 24)
                    Canvas { ctx, s in
                        var check = Path()
                        check.move(to:    CGPoint(x: s.width * 0.27, y: s.height * 0.52))
                        check.addLine(to: CGPoint(x: s.width * 0.45, y: s.height * 0.68))
                        check.addLine(to: CGPoint(x: s.width * 0.73, y: s.height * 0.35))
                        ctx.stroke(check, with: .color(.white),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    .frame(width: 24, height: 24)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isSelected ? ink.opacity(0.05) : Color.clear)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.2)
            Text("Loading contacts...")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorStateView(_ message: String) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.secondary, lineWidth: 2)
                    .frame(width: 48, height: 48)
                Text("!")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.secondary)
            }
            Text("Contacts Unavailable")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Try Again") {
                didRequestContacts = false
                loadContactsIfNeeded()
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            // Custom empty state: magnifying glass with X
            ZStack {
                Circle()
                    .stroke(Color.secondary, lineWidth: 2)
                    .frame(width: 48, height: 48)
                Canvas { ctx, s in
                    let w = s.width, h = s.height
                    let sw: CGFloat = 2.0
                    let pad: CGFloat = 0.28
                    var d1 = Path()
                    d1.move(to:    CGPoint(x: w * pad,       y: h * pad))
                    d1.addLine(to: CGPoint(x: w * (1 - pad), y: h * (1 - pad)))
                    ctx.stroke(d1, with: .color(Color.secondary), lineWidth: sw)
                    var d2 = Path()
                    d2.move(to:    CGPoint(x: w * (1 - pad), y: h * pad))
                    d2.addLine(to: CGPoint(x: w * pad,       y: h * (1 - pad)))
                    ctx.stroke(d2, with: .color(Color.secondary), lineWidth: sw)
                }
                .frame(width: 48, height: 48)
            }
            Text("No Contacts Found")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
            Text("Make sure you've granted access to your contacts")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadContactsIfNeeded() {
        guard !didRequestContacts else { return }
        didRequestContacts = true
        isLoading = true
        loadErrorMessage = nil
        allContacts = []
        loadContacts()
    }

    private func loadContacts() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized, .limited:
            fetchContacts()
        case .notDetermined:
            CNContactStore().requestAccess(for: .contacts) { granted, _ in
                if granted {
                    fetchContacts()
                } else {
                    DispatchQueue.main.async {
                        isLoading = false
                        loadErrorMessage = "Allow Contacts access in Settings to add people from your phone."
                    }
                }
            }
        case .denied, .restricted:
            isLoading = false
            loadErrorMessage = "Allow Contacts access in Settings to add people from your phone."
        @unknown default:
            fetchContacts()
        }
    }

    private func fetchContacts() {
        DispatchQueue.global(qos: .userInitiated).async {
            let start = CFAbsoluteTimeGetCurrent()
            let store = CNContactStore()
            let keysToFetch: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor
            ]
            var loadedContacts: [CNContact] = []
            var batch: [CNContact] = []
            let request = CNContactFetchRequest(keysToFetch: keysToFetch)
            request.sortOrder = .userDefault
            func publish(_ contacts: [CNContact]) {
                guard !contacts.isEmpty else { return }
                DispatchQueue.main.async {
                    if isLoading { isLoading = false }
                    allContacts.append(contentsOf: contacts)
                    loadErrorMessage = nil
                }
            }
            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    guard !contact.phoneNumbers.isEmpty else { return }
                    loadedContacts.append(contact)
                    batch.append(contact)
                    if batch.count >= 80 {
                        let contactsToPublish = batch
                        batch.removeAll(keepingCapacity: true)
                        publish(contactsToPublish)
                    }
                }
                publish(batch)
                let sortedContacts = ContactRanking.sortedLightweight(loadedContacts)
                DispatchQueue.main.async {
                    allContacts = sortedContacts
                    loadErrorMessage = nil
                    isLoading = false
                    let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    if elapsedMs > 100 {
                        print("🧭 PERF [contacts:people-load] count=\(sortedContacts.count) ms=\(elapsedMs)")
                    }
                }
            } catch {
                print("Failed to fetch contacts: \(error)")
                DispatchQueue.main.async {
                    isLoading = false
                    loadErrorMessage = "Could not load contacts. Please try again."
                }
            }
        }
    }

    private func toggleContact(_ contact: CNContact) {
        HapticManager.impact(style: .light)
        if selectedContacts.contains(contact.identifier) {
            selectedContacts.remove(contact.identifier)
        } else {
            selectedContacts.insert(contact.identifier)
        }
    }

    private func completeSelection() {
        let ids = selectedContacts
        let lightweightSelection = allContacts.filter { ids.contains($0.identifier) }
        guard !lightweightSelection.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let store = CNContactStore()
            let keysToFetch: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactNicknameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactImageDataKey as CNKeyDescriptor,
                CNContactThumbnailImageDataKey as CNKeyDescriptor
            ]

            var hydrated: [CNContact] = []
            for id in ids {
                guard let contact = try? store.unifiedContact(withIdentifier: id, keysToFetch: keysToFetch) else { continue }
                hydrated.append(contact)
            }

            DispatchQueue.main.async {
                onContactsSelected(hydrated.isEmpty ? lightweightSelection : hydrated)
                dismiss()
            }
        }
    }
}

// MARK: - System Contact Picker (UIKit wrapper)

struct ContactPickerView: UIViewControllerRepresentable {
    let onContactsSelected: ([CNContact]) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: ContactPickerView
        init(_ parent: ContactPickerView) { self.parent = parent }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            parent.onContactsSelected(contacts)
            parent.dismiss()
        }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { parent.dismiss() }
    }
}
