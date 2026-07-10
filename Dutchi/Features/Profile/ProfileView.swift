import SwiftUI
import PhotosUI
import MessageUI
import Combine
import FirebaseAuth
import UIKit

// MARK: - Dutch Custom Icons (Profile)

/// Camera body — RoundedRect outline, small rect bump on top, stroke circle for lens, filled dot center.
struct CameraIcon: View {
    var size: CGFloat = 16
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5

            let body = Path(roundedRect: CGRect(x: w * 0.06, y: h * 0.28, width: w * 0.88, height: h * 0.58), cornerRadius: 2)
            ctx.stroke(body, with: .color(.white), lineWidth: sw)

            let bump = CGRect(x: w * 0.36, y: h * 0.14, width: w * 0.28, height: h * 0.16)
            let bumpPath = Path(roundedRect: bump, cornerRadius: 1)
            ctx.stroke(bumpPath, with: .color(.white), lineWidth: sw)

            let lr: CGFloat = w * 0.2
            let lx = w / 2, ly = h * 0.57
            let lens = Path(ellipseIn: CGRect(x: lx - lr, y: ly - lr, width: lr * 2, height: lr * 2))
            ctx.stroke(lens, with: .color(.white), lineWidth: sw)

            let dr: CGFloat = w * 0.07
            let dot = Path(ellipseIn: CGRect(x: lx - dr, y: ly - dr, width: dr * 2, height: dr * 2))
            ctx.fill(dot, with: .color(.white))
        }
        .frame(width: size, height: size)
    }
}

/// Shield with a checkmark.
struct ShieldCheckIcon: View {
    var size: CGFloat = 22
    var color: Color = .secondary

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5

            var shield = Path()
            shield.move(to:    CGPoint(x: w * 0.5,  y: h * 0.06))
            shield.addLine(to: CGPoint(x: w * 0.92, y: h * 0.26))
            shield.addLine(to: CGPoint(x: w * 0.92, y: h * 0.58))
            shield.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.94),
                            control1: CGPoint(x: w * 0.92, y: h * 0.82),
                            control2: CGPoint(x: w * 0.72, y: h * 0.90))
            shield.addCurve(to: CGPoint(x: w * 0.08, y: h * 0.58),
                            control1: CGPoint(x: w * 0.28, y: h * 0.90),
                            control2: CGPoint(x: w * 0.08, y: h * 0.82))
            shield.addLine(to: CGPoint(x: w * 0.08, y: h * 0.26))
            shield.closeSubpath()
            ctx.fill(shield, with: .color(color.opacity(0.15)))
            ctx.stroke(shield, with: .color(color), lineWidth: sw)

            var check = Path()
            check.move(to:    CGPoint(x: w * 0.32, y: h * 0.53))
            check.addLine(to: CGPoint(x: w * 0.46, y: h * 0.67))
            check.addLine(to: CGPoint(x: w * 0.70, y: h * 0.40))
            ctx.stroke(check, with: .color(color),
                       style: StrokeStyle(lineWidth: sw, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

struct VenmoIcon: View {
    var size: CGFloat = 22
    var color: Color = .secondary

    var body: some View {
        Image("venmo-icon")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

struct ZelleIcon: View {
    var size: CGFloat = 22
    var color: Color = .secondary

    var body: some View {
        Image("zelle-icon")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

/// QR code icon — kept for any remaining usages elsewhere in the codebase.
struct QRCodeIcon: View {
    var size: CGFloat = 22
    var color: Color = .secondary

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5
            let m: CGFloat = w * 0.08

            let outer = Path(roundedRect: CGRect(x: m, y: m, width: w - m*2, height: h - m*2), cornerRadius: 1)
            ctx.stroke(outer, with: .color(color), lineWidth: sw)

            let cs: CGFloat = w * 0.28
            let csm: CGFloat = m + w * 0.05
            func cornerSquare(_ ox: CGFloat, _ oy: CGFloat) {
                let sq = Path(roundedRect: CGRect(x: ox, y: oy, width: cs, height: cs), cornerRadius: 1)
                ctx.stroke(sq, with: .color(color), lineWidth: sw)
                let inset: CGFloat = w * 0.07
                let inner = Path(CGRect(x: ox + inset, y: oy + inset, width: cs - inset*2, height: cs - inset*2))
                ctx.fill(inner, with: .color(color))
            }
            cornerSquare(csm, csm)
            cornerSquare(w - csm - cs, csm)
            cornerSquare(csm, h - csm - cs)

            let dotR: CGFloat = w * 0.06
            let dots: [CGPoint] = [
                CGPoint(x: w * 0.62, y: h * 0.62),
                CGPoint(x: w * 0.75, y: h * 0.62),
                CGPoint(x: w * 0.62, y: h * 0.75),
            ]
            for d in dots {
                let dot = Path(ellipseIn: CGRect(x: d.x - dotR, y: d.y - dotR, width: dotR*2, height: dotR*2))
                ctx.fill(dot, with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Padlock (closed).
struct LockIcon: View {
    var size: CGFloat = 28
    var color: Color = .secondary

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5

            let body = Path(roundedRect: CGRect(x: w * 0.18, y: h * 0.46, width: w * 0.64, height: h * 0.44), cornerRadius: 2)
            ctx.stroke(body, with: .color(color), lineWidth: sw)

            var shackle = Path()
            shackle.move(to:    CGPoint(x: w * 0.32, y: h * 0.46))
            shackle.addLine(to: CGPoint(x: w * 0.32, y: h * 0.28))
            shackle.addArc(center: CGPoint(x: w * 0.5, y: h * 0.28),
                           radius: w * 0.18,
                           startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            shackle.addLine(to: CGPoint(x: w * 0.68, y: h * 0.46))
            ctx.stroke(shackle, with: .color(color), lineWidth: sw)

            let kr: CGFloat = w * 0.06
            let khole = Path(ellipseIn: CGRect(x: w*0.5 - kr, y: h*0.60, width: kr*2, height: kr*2))
            ctx.fill(khole, with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

/// Play triangle.
struct PlayIcon: View {
    var size: CGFloat = 16
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            var tri = Path()
            tri.move(to:    CGPoint(x: w * 0.28, y: h * 0.18))
            tri.addLine(to: CGPoint(x: w * 0.80, y: h * 0.50))
            tri.addLine(to: CGPoint(x: w * 0.28, y: h * 0.82))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(ink))
        }
        .frame(width: size, height: size)
    }
}

/// Ledger mark for money received.
struct ArrowDownIcon: View {
    var size: CGFloat = 16
    var color: Color = .green

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let stroke: CGFloat = max(1.6, w * 0.09)

            let circle = Path(ellipseIn: CGRect(x: w * 0.18, y: h * 0.18, width: w * 0.64, height: h * 0.64))
            ctx.stroke(circle, with: .color(color), lineWidth: stroke)

            var plus = Path()
            plus.move(to: CGPoint(x: w * 0.34, y: h * 0.50))
            plus.addLine(to: CGPoint(x: w * 0.66, y: h * 0.50))
            plus.move(to: CGPoint(x: w * 0.50, y: h * 0.34))
            plus.addLine(to: CGPoint(x: w * 0.50, y: h * 0.66))
            ctx.stroke(plus, with: .color(color), lineWidth: stroke)
        }
        .frame(width: size, height: size)
    }
}

/// Ledger mark for money owed.
struct ArrowUpIcon: View {
    var size: CGFloat = 16
    var color: Color = .red

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let stroke: CGFloat = max(1.6, w * 0.09)

            let circle = Path(ellipseIn: CGRect(x: w * 0.18, y: h * 0.18, width: w * 0.64, height: h * 0.64))
            ctx.stroke(circle, with: .color(color), lineWidth: stroke)

            var minus = Path()
            minus.move(to: CGPoint(x: w * 0.34, y: h * 0.50))
            minus.addLine(to: CGPoint(x: w * 0.66, y: h * 0.50))
            ctx.stroke(minus, with: .color(color), lineWidth: stroke)
        }
        .frame(width: size, height: size)
    }
}

/// Arrow pointing right (small, inline).
struct ArrowRightSmallIcon: View {
    var size: CGFloat = 16
    var color: Color = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.8
            var shaft = Path()
            shaft.move(to:    CGPoint(x: w * 0.12, y: h * 0.5))
            shaft.addLine(to: CGPoint(x: w * 0.78, y: h * 0.5))
            ctx.stroke(shaft, with: .color(color), lineWidth: sw)
            var head = Path()
            head.move(to:    CGPoint(x: w * 0.55, y: h * 0.22))
            head.addLine(to: CGPoint(x: w * 0.88, y: h * 0.5))
            head.addLine(to: CGPoint(x: w * 0.55, y: h * 0.78))
            ctx.stroke(head, with: .color(color), lineWidth: sw)
        }
        .frame(width: size, height: size)
    }
}

/// Plus inside a circle.
struct PlusCircleIcon: View {
    var size: CGFloat = 22
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5

            let ring = Path(ellipseIn: CGRect(x: 1, y: 1, width: w - 2, height: h - 2))
            ctx.fill(ring, with: .color(ink))

            let pad: CGFloat = w * 0.28
            var h_line = Path()
            h_line.move(to:    CGPoint(x: pad,     y: h / 2))
            h_line.addLine(to: CGPoint(x: w - pad, y: h / 2))
            ctx.stroke(h_line, with: .color(.white), lineWidth: sw)

            var v_line = Path()
            v_line.move(to:    CGPoint(x: w / 2, y: pad))
            v_line.addLine(to: CGPoint(x: w / 2, y: h - pad))
            ctx.stroke(v_line, with: .color(.white), lineWidth: sw)
        }
        .frame(width: size, height: size)
    }
}

/// QR code + plus (empty state).
struct QRPlusIcon: View {
    var size: CGFloat = 20
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5

            let qSize: CGFloat = w * 0.55
            let qOuter = Path(roundedRect: CGRect(x: 0, y: h*0.1, width: qSize, height: qSize), cornerRadius: 1)
            ctx.stroke(qOuter, with: .color(ink.opacity(0.5)), lineWidth: sw)
            let cs: CGFloat = qSize * 0.3
            let qCorners = [CGPoint(x: qSize*0.1, y: h*0.1 + qSize*0.1),
                            CGPoint(x: qSize*0.6, y: h*0.1 + qSize*0.1)]
            for c in qCorners {
                let sq = Path(CGRect(x: c.x, y: c.y, width: cs, height: cs))
                ctx.stroke(sq, with: .color(ink.opacity(0.5)), lineWidth: sw)
            }
            let bot = CGPoint(x: qSize*0.1, y: h*0.1 + qSize*0.6)
            let sq3 = Path(CGRect(x: bot.x, y: bot.y, width: cs, height: cs))
            ctx.stroke(sq3, with: .color(ink.opacity(0.5)), lineWidth: sw)

            let px: CGFloat = w * 0.72, py: CGFloat = h * 0.55
            let pr: CGFloat = w * 0.2
            var hp = Path(); hp.move(to: CGPoint(x: px - pr, y: py)); hp.addLine(to: CGPoint(x: px + pr, y: py))
            var vp = Path(); vp.move(to: CGPoint(x: px, y: py - pr)); vp.addLine(to: CGPoint(x: px, y: py + pr))
            ctx.stroke(hp, with: .color(ink), lineWidth: sw)
            ctx.stroke(vp, with: .color(ink), lineWidth: sw)
        }
        .frame(width: size, height: size)
    }
}

/// Trash / bin.
struct TrashIcon: View {
    var size: CGFloat = 16
    var color: Color = .red

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5

            var lid = Path()
            lid.move(to:    CGPoint(x: w * 0.12, y: h * 0.26))
            lid.addLine(to: CGPoint(x: w * 0.88, y: h * 0.26))
            ctx.stroke(lid, with: .color(color), lineWidth: sw)

            var handle = Path()
            handle.move(to:    CGPoint(x: w * 0.38, y: h * 0.26))
            handle.addLine(to: CGPoint(x: w * 0.38, y: h * 0.14))
            handle.addLine(to: CGPoint(x: w * 0.62, y: h * 0.14))
            handle.addLine(to: CGPoint(x: w * 0.62, y: h * 0.26))
            ctx.stroke(handle, with: .color(color), lineWidth: sw)

            let body = Path(roundedRect: CGRect(x: w * 0.18, y: h * 0.26, width: w * 0.64, height: h * 0.62), cornerRadius: 1)
            ctx.stroke(body, with: .color(color), lineWidth: sw)

            for xf in [CGFloat(0.38), 0.50, 0.62] {
                var line = Path()
                line.move(to:    CGPoint(x: w * xf, y: h * 0.38))
                line.addLine(to: CGPoint(x: w * xf, y: h * 0.76))
                ctx.stroke(line, with: .color(color), lineWidth: sw)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Verified seal.
struct VerifiedSealIcon: View {
    var size: CGFloat = 14
    var color: Color = .green

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5

            let ring = Path(ellipseIn: CGRect(x: 1, y: 1, width: w - 2, height: h - 2))
            ctx.stroke(ring, with: .color(color), lineWidth: sw)

            var check = Path()
            check.move(to:    CGPoint(x: w * 0.28, y: h * 0.52))
            check.addLine(to: CGPoint(x: w * 0.45, y: h * 0.68))
            check.addLine(to: CGPoint(x: w * 0.72, y: h * 0.35))
            ctx.stroke(check, with: .color(color),
                       style: StrokeStyle(lineWidth: sw, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

/// Single person icon.
struct ProfilePersonIcon: View {
    var size: CGFloat = 18
    var color: Color = Color.secondary

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5
            let cx = w / 2

            let headR = w * 0.18
            let headY = h * 0.06
            let headRect = CGRect(x: cx - headR, y: headY, width: headR * 2, height: headR * 2)
            let headPath = Path(ellipseIn: headRect)
            ctx.stroke(headPath, with: .color(color), lineWidth: sw)

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
            ctx.stroke(body, with: .color(color), lineWidth: sw)
        }
        .frame(width: size, height: size)
    }
}

/// Phone handset.
struct PhoneProfileIcon: View {
    var size: CGFloat = 18
    var color: Color = .secondary

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5
            let rect = CGRect(x: w * 0.22, y: h * 0.08, width: w * 0.56, height: h * 0.84)
            let body = Path(roundedRect: rect, cornerRadius: 2)
            ctx.stroke(body, with: .color(color), lineWidth: sw)
            var ear = Path()
            ear.move(to:    CGPoint(x: w * 0.38, y: h * 0.20))
            ear.addLine(to: CGPoint(x: w * 0.62, y: h * 0.20))
            ctx.stroke(ear, with: .color(color), lineWidth: sw)
        }
        .frame(width: size, height: size)
    }
}

/// Group icon — two figures.
struct GroupProfileIcon: View {
    var size: CGFloat = 16
    var color: Color = .secondary

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5

            func drawFigure(cx: CGFloat, headY: CGFloat, scale: CGFloat) {
                let headR = w * 0.115 * scale
                let headRect = CGRect(x: cx - headR, y: headY, width: headR * 2, height: headR * 2)
                let headPath = Path(ellipseIn: headRect)
                ctx.stroke(headPath, with: .color(color), lineWidth: sw)

                let bodyTop    = headY + headR * 2 + h * 0.03
                let bodyBottom = h * 0.82
                let topW = headR * 1.4 * scale
                let botW = headR * 2.0 * scale
                var bodyPath = Path()
                bodyPath.move(to:    CGPoint(x: cx - topW, y: bodyTop))
                bodyPath.addLine(to: CGPoint(x: cx + topW, y: bodyTop))
                bodyPath.addLine(to: CGPoint(x: cx + botW, y: bodyBottom))
                bodyPath.addLine(to: CGPoint(x: cx - botW, y: bodyBottom))
                bodyPath.closeSubpath()
                ctx.stroke(bodyPath, with: .color(color), lineWidth: sw)
            }

            drawFigure(cx: w * 0.32, headY: h * 0.08, scale: 0.85)
            drawFigure(cx: w * 0.68, headY: h * 0.08, scale: 0.85)

            var ground = Path()
            ground.move(to:    CGPoint(x: w * 0.08, y: h * 0.88))
            ground.addLine(to: CGPoint(x: w * 0.92, y: h * 0.88))
            ctx.stroke(ground, with: .color(color), lineWidth: sw)
        }
        .frame(width: size, height: size)
    }
}

/// Chevron pointing right.
struct ChevronRightProfileIcon: View {
    var size: CGFloat = 14
    var color: Color = .secondary

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            var p = Path()
            p.move(to:    CGPoint(x: w * 0.3, y: h * 0.2))
            p.addLine(to: CGPoint(x: w * 0.7, y: h * 0.5))
            p.addLine(to: CGPoint(x: w * 0.3, y: h * 0.8))
            ctx.stroke(p, with: .color(color), lineWidth: 1.5)
        }
        .frame(width: size, height: size)
    }
}

/// X mark.
struct XMarkProfileIcon: View {
    var size: CGFloat = 14
    var color: Color = Color(.label).opacity(0.7)

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.5
            let pad: CGFloat = 0.22
            var d1 = Path()
            d1.move(to:    CGPoint(x: w * pad,       y: h * pad))
            d1.addLine(to: CGPoint(x: w * (1 - pad), y: h * (1 - pad)))
            ctx.stroke(d1, with: .color(color), lineWidth: sw)
            var d2 = Path()
            d2.move(to:    CGPoint(x: w * (1 - pad), y: h * pad))
            d2.addLine(to: CGPoint(x: w * pad,       y: h * (1 - pad)))
            ctx.stroke(d2, with: .color(color), lineWidth: sw)
        }
        .frame(width: size, height: size)
    }
}

/// Arrow right for tutorial cards (white).
struct ArrowRightTutorialIcon: View {
    var size: CGFloat = 14

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw: CGFloat = 1.8
            var shaft = Path()
            shaft.move(to:    CGPoint(x: w * 0.12, y: h * 0.5))
            shaft.addLine(to: CGPoint(x: w * 0.78, y: h * 0.5))
            ctx.stroke(shaft, with: .color(.white), lineWidth: sw)
            var head = Path()
            head.move(to:    CGPoint(x: w * 0.55, y: h * 0.22))
            head.addLine(to: CGPoint(x: w * 0.88, y: h * 0.5))
            head.addLine(to: CGPoint(x: w * 0.55, y: h * 0.78))
            ctx.stroke(head, with: .color(.white), lineWidth: sw)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - PaywallSheetConfig

struct PaywallSheetConfig: Identifiable {
    let id = UUID()
    let startsPaidImmediately: Bool
    let opensSubscriptionInvite: Bool
    let managedSubscriptionGroupID: UUID?

    init(
        startsPaidImmediately: Bool,
        opensSubscriptionInvite: Bool,
        managedSubscriptionGroupID: UUID? = nil
    ) {
        self.startsPaidImmediately = startsPaidImmediately
        self.opensSubscriptionInvite = opensSubscriptionInvite
        self.managedSubscriptionGroupID = managedSubscriptionGroupID
    }
}

// MARK: - ProfileView

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tutorialManager: TutorialManager
    @EnvironmentObject var router: Router
    @EnvironmentObject var authManager: AuthManager
    @StateObject private var groupManager = GroupManager.shared
    @StateObject private var notificationManager = NotificationManager.shared
    @StateObject private var trialManager = TrialManager.shared
    @StateObject private var networkMonitor = NetworkStatusMonitor.shared
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedQRCodeItem: PhotosPickerItem?
    @State private var showingAvatarPicker = false
    @State private var showingQRPicker = false
    @State private var selectedHistoryRecord: SplitRecord?
    @State private var showHistoryBrowser = false
    @State private var historySearchText = ""
    @State private var showPhoneVerification = false
    @State private var showQRScanError = false
    @State private var qrScanErrorMessage = ""
    @State private var scrollProxy: ScrollViewProxy? = nil

    @State private var isEditingProfile = false
    @State private var isEditingVenmo = false
    @State private var isExpandingHistory = false
    @State private var paywallConfig: PaywallSheetConfig? = nil
    @State private var subscriptionPeopleManagerConfig: SubscriptionPeopleManagerConfig? = nil
    @State private var resolvedSharedSubscriptionGroup: DutchieGroup?


    @State private var showGroupNameSheet = false
    @State private var showDeleteAccountAlert = false
    @State private var deleteAccountErrorMessage = ""
    @State private var showDeleteAccountError = false
    @State private var showDeveloperPanel = false
    @State private var notificationObserverTokens: [NSObjectProtocol] = []
    @State private var didDeferHeavyProfileSections = false
    @State private var cachedSubscriptionInviteGroup: DutchieGroup?
    @State private var cachedPlanRoster: [GroupMember] = []
    @State private var cachedPlanLimit: Int?
    @State private var paymentSyncWorkItem: DispatchWorkItem?
    @State private var profileRenderWorkItem: DispatchWorkItem?
    @State private var lastSubscriptionMemberSyncKey = ""

    @State private var pendingInvite: PendingGroupInvite?
    @State private var showGroupJoin = false

    @State private var showJoinBanner = false
    @State private var joinedMemberName = ""
    @StateObject private var groupModeTutorial = GroupModeTutorialManager()
    @State private var joinedGroupName = ""
    @State private var isLastJoinedMember = false

    // MARK: - Readiness

    private var isPhoneVerified: Bool { authManager.isAuthenticated }
    private var isVenmoConnected: Bool {
        guard let v = appState.profile.venmoUsername else { return false }
        return !v.isEmpty
    }
    private var isZelleConnected: Bool {
        appState.profile.zelleQRCode != nil
    }
    
    private var readinessCount: Int {
        [isPhoneVerified, isVenmoConnected, isZelleConnected].filter { $0 }.count
    }
    private var isFullyReady: Bool { readinessCount == 3 }

    private var readinessMessage: String {
        if isFullyReady { return "Ready to receive payments" }
        if readinessCount == 0 { return "Finish payment setup to get started" }
        return "\(readinessCount) of 3 steps complete"
    }

    private var shouldHighlightPaymentSection: Bool {
        tutorialManager.isActive && tutorialManager.currentStepIndex == 9 && tutorialManager.currentStep?.targetView == .paymentMethods
    }

    private var subscriptionInviteGroup: DutchieGroup? {
        if let resolvedSharedSubscriptionGroup {
            return resolvedSharedSubscriptionGroup
        }

        if let sharedGroupID = trialManager.sharedSubscriptionGroupID,
           let sharedGroup = groupManager.getGroup(by: sharedGroupID) {
            return sharedGroup
        }

        if trialManager.sharedSubscriptionGroupID != nil {
            return nil
        }

        return groupManager.currentUserSubscriptionInviteGroups.first { $0.maxMemberCount != nil }
        ?? groupManager.currentUserAvailableGroups.first { $0.maxMemberCount != nil }
        ?? groupManager.activeGroup.flatMap { groupManager.isAvailableToCurrentUser($0) ? $0 : nil }
    }

    private var cachedManagedSubscriptionGroupID: UUID? {
        trialManager.sharedSubscriptionGroupID
        ?? trialManager.ownedSubscriptionGroupID
        ?? cachedSubscriptionInviteGroup?.id
    }

    private var filteredHistory: [SplitRecord] {
        if historySearchText.isEmpty { return appState.profile.splitHistory }
        let q = historySearchText.lowercased()
        return appState.profile.splitHistory.filter { r in
            r.formattedTotal.lowercased().contains(q) ||
            r.formattedDate.lowercased().contains(q) ||
            "\(r.participantCount)".contains(q) ||
            r.settlements.contains { $0.fromName.lowercased().contains(q) || $0.toName.lowercased().contains(q) }
        }
    }

    // MARK: - Colors

    private let ivory  = Color(red: 1.0,  green: 0.992, blue: 0.969)
    private let ink    = Color(red: 0.15, green: 0.15,  blue: 0.15)
    private let chalk  = Color(red: 0.96, green: 0.96,  blue: 0.94)

    var body: some View {
        NavigationView {
            ZStack {
                ivory.ignoresSafeArea()
                scrollContent
                tutorialOverlayIfNeeded
                joinBannerIfNeeded
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closeButton }
        }
        .onChange(of: selectedPhoto) { _, newValue in
            Task {
                if let data = try? await newValue?.loadTransferable(type: Data.self) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        appState.profile.avatarImage = data
                    }
                }
                selectedPhoto = nil
            }
        }
        .onChange(of: selectedQRCodeItem) { _, newValue in
            Task {
                await handleQRCodeSelection(newValue)
                selectedQRCodeItem = nil
                showingQRPicker = false
            }
        }
        .onChange(of: appState.profile.venmoUsername) { _, _ in schedulePaymentInfoSync() }
        .onChange(of: appState.profile.venmoPaymentLink) { _, _ in schedulePaymentInfoSync() }
        .onChange(of: appState.profile.zelleContactInfo) { _, _ in schedulePaymentInfoSync() }
        .onChange(of: appState.profile.zellePaymentLink) { _, _ in schedulePaymentInfoSync() }
        .onChange(of: appState.profile.zelleQRCode) { _, _ in schedulePaymentInfoSync() }
        .sheet(item: $selectedHistoryRecord) { record in
            NavigationView { SplitHistoryDetailView(record: record) }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showHistoryBrowser) {
            SplitHistoryBrowserView(records: appState.profile.splitHistory)
                .environmentObject(appState)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPhoneVerification) {
            PhoneVerificationSheet(
                authManager: authManager,
                prefilledPhone: appState.profile.zelleContactInfo ?? "",
                isPresented: $showPhoneVerification
            )
        }
        .sheet(item: $paywallConfig) { config in
            PaywallView(
                startsPaidImmediately: config.startsPaidImmediately,
                opensSubscriptionInvite: config.opensSubscriptionInvite,
                managedSubscriptionGroupID: config.managedSubscriptionGroupID
            )
            .environmentObject(appState)
        }
        .sheet(item: $subscriptionPeopleManagerConfig) { config in
            SubscriptionPeopleManagerView(managedSubscriptionGroupID: config.managedSubscriptionGroupID)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showGroupJoin) { groupJoinSheetContent }
        .sheet(isPresented: $showGroupNameSheet) { groupNameSheetContent }
        .alert("QR Code Error", isPresented: $showQRScanError) {
            Button("OK", role: .cancel) { }
        } message: { Text(qrScanErrorMessage) }
        .alert("Delete Account?", isPresented: $showDeleteAccountAlert) {
            Button("Delete Account", role: .destructive) {
                deferProfileAction {
                    deleteAccount()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes your Dutch sign-in account and local app data on this device. This cannot be undone.")
        }
        .alert("Could Not Delete Account", isPresented: $showDeleteAccountError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(deleteAccountErrorMessage)
        }
        .onAppear { setupOnAppear() }
        .onDisappear {
            paymentSyncWorkItem?.cancel()
            paymentSyncWorkItem = nil
            profileRenderWorkItem?.cancel()
            profileRenderWorkItem = nil
            tearDownNotificationObservers()
        }
        .onChange(of: trialManager.sharedSubscriptionGroupID) { _, newGroupID in
            refreshSharedSubscriptionGroup(groupID: newGroupID)
        }
        .onReceive(groupManager.$allGroups) { groups in
            guard let sharedGroupID = trialManager.sharedSubscriptionGroupID,
                  let sharedGroup = groups.first(where: { $0.id == sharedGroupID }) else {
                return
            }
            resolvedSharedSubscriptionGroup = sharedGroup
            if didDeferHeavyProfileSections {
                scheduleProfileRenderCache(reason: "groups-update-shared")
            }
        }
    }
    // MARK: - Tutorial Replay Rows

    private var tutorialReplayRow: some View {
        VStack(spacing: 12) {
            // Main App Tutorial
            Button(action: {
                HapticManager.impact(style: .medium)
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    router.resetToUpload()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        tutorialManager.start()
                    }
                }
            }) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(ink.opacity(0.1)).frame(width: 36, height: 36)
                        PlayIcon(size: 14)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Replay App Tutorial")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(ink)
                        Text("Learn the basics of splitting bills")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    ChevronRightProfileIcon(size: 13, color: .secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(chalk)
                .cornerRadius(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(ink, lineWidth: 1.5)
                )
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.98))
            
            // Group Mode Tutorial
            Button(action: replayGroupModeTutorial) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(ink.opacity(0.1)).frame(width: 36, height: 36)
                        GroupProfileIcon(size: 16, color: ink)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Replay Group Mode Tutorial")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(ink)
                        Text("Learn how to split with groups")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    ChevronRightProfileIcon(size: 13, color: .secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(chalk)
                .cornerRadius(2)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(ink, lineWidth: 1.5)
                )
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.98))
        }
    }

    private func replayGroupModeTutorial() {
        HapticManager.impact(style: .medium)
        
        // Dismiss profile
        dismiss()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Reset to upload view
            router.resetToUpload()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Wire up dependencies
                groupModeTutorial.router = router
                groupModeTutorial.appState = appState
                groupModeTutorial.groupManager = groupManager
                
                // Reset and start
                groupModeTutorial.reset()
                groupModeTutorial.start()
                
                print("🎯 Group Mode Tutorial replay initiated")
            }
        }
    }
    
    private func findGroupModeTutorialManager() -> GroupModeTutorialManager? {
        // Option 1: If you have it as an EnvironmentObject
        // Return the environment object
        
        // Option 2: If you have it as a singleton/shared instance
        // Return GroupModeTutorialManager.shared
        
        // Option 3: Access from router if it stores it
        // return router.groupModeTutorial
        
        // For now, create a temporary instance
        // TODO: Replace with proper access to your GroupModeTutorialManager
        let manager = GroupModeTutorialManager()
        return manager
    }
    
    
    private var scrollContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    heroHeader
                        .padding(.bottom, 24)

                    VStack(spacing: 16) {
                        paymentReadinessCard
                            .id("paymentSection")

                        profileCard

                        if didDeferHeavyProfileSections {
                            proTrialCard

                            historyCard

                            if !tutorialManager.isActive && !groupModeTutorial.isActive {
                                tutorialReplayRow
                            }
                        } else {
                            profileLoadingCard
                        }

                        signOutRow

                        if isDeveloperPhone(authManager.phoneNumber) {
                            developerPanelButton
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 60)
                }
            }
            .onAppear { scrollProxy = proxy }
        }
    }

    private var profileLoadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(ink)
            Text("Loading profile details")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(20)
        .background(chalk)
        .cornerRadius(2)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(ink.opacity(0.35), lineWidth: 1.2)
        )
    }
    
    // MARK: - Hero Header

    private var heroHeader: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(
                    imageData: appState.profile.avatarImage,
                    initials: appState.profile.initials,
                    size: 96
                )
                .shadow(color: ink.opacity(0.10), radius: 16, y: 6)

                Button(action: { HapticManager.impact(style: .medium); showingAvatarPicker = true }) {
                    ZStack {
                        Circle().fill(ink).frame(width: 30, height: 30)
                            .shadow(color: ink.opacity(0.25), radius: 6, y: 3)
                        CameraIcon(size: 14)
                    }
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.9))
                .offset(x: 3, y: 3)
            }
            .photosPicker(isPresented: $showingAvatarPicker, selection: $selectedPhoto, matching: .images)

            VStack(spacing: 4) {
                Text(appState.profile.name.isEmpty ? "Set your name" : appState.profile.name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(ink)

                HStack(spacing: 6) {
                    Circle()
                        .fill(isFullyReady ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(readinessMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isFullyReady ? Color.green : Color.orange)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private var paymentReadinessCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Get Paid")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(ink)
                    Text("\(readinessCount) of 3 complete")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                ZStack {
                    Circle()
                        .stroke(chalk, lineWidth: 4)
                        .frame(width: 44, height: 44)
                    Circle()
                        .trim(from: 0, to: CGFloat(readinessCount) / 3.0)
                        .stroke(isFullyReady ? Color.green : ink,
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 44, height: 44)
                    Text("\(readinessCount)/3")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(ink)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            Rectangle()
                .fill(ink)
                .frame(height: 1.5)
                .padding(.horizontal, 20)
            
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    setupChip(title: isPhoneVerified ? "PHONE VERIFIED" : "VERIFY PHONE", isDone: isPhoneVerified) {
                        if !isPhoneVerified { showPhoneVerification = true }
                    }
                    setupChip(title: "\(readinessCount)/3 READY", isDone: isFullyReady, action: nil)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)

                paymentStatusRow(
                    iconView: AnyView(VenmoIcon(size: 22, color: isVenmoConnected ? Color(red: 0.2, green: 0.53, blue: 0.96) : .secondary)),
                    title: "Venmo",
                    subtitle: isVenmoConnected
                    ? "@\(appState.profile.venmoUsername ?? "")"
                    : "Add username",
                    isDone: isVenmoConnected,
                    action: { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isEditingVenmo.toggle() } }
                )
                
                if isEditingVenmo {
                    venmoEditInline
                        .padding(.leading, 56)
                        .padding(.trailing, 20)
                        .padding(.bottom, 16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                paymentStatusRow(
                    iconView: AnyView(
                        ZelleIcon(
                            size: 22,
                            color: isZelleConnected
                            ? Color(red: 0.38, green: 0.16, blue: 0.58)
                            : .secondary
                        )
                    ),
                    title: "Zelle",
                    subtitle: zelleStatusText,
                    isDone: isZelleConnected,
                    action: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isEditingZelle.toggle()
                        }
                    }
                )
                
                if isEditingZelle {
                    zelleEditInline
                        .padding(.leading, 56)
                        .padding(.trailing, 20)
                        .padding(.bottom, 16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.bottom, 4)
            
            // CTA
            if !isFullyReady {
                Button(action: {
                    HapticManager.impact(style: .medium)
                    withAnimation(.easeInOut(duration: 0.4)) {
                        scrollProxy?.scrollTo("paymentSection", anchor: .top)
                    }
                    if !isPhoneVerified { showPhoneVerification = true }
                    else if !isVenmoConnected { isEditingVenmo = true }
                    else { isEditingZelle = true }
                }) {
                    Text("FINISH SETUP")
                        .font(.system(size: 13, weight: .bold))
                        .tracking(1)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(ink)
                        .cornerRadius(2)
                }
                .buttonStyle(ScaleButtonStyle())
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
            } else {
                Spacer().frame(height: 20)
            }
        }
        .background(chalk)
        .cornerRadius(2)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(ink, lineWidth: 1.5)
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TutorialFrameKey.self,
                    value: (tutorialManager.isActive && tutorialManager.currentStepIndex == 8 && tutorialManager.currentStep?.targetView == .paymentMethods)
                    ? geo.frame(in: .global)
                    : .zero
                )
            }
        )
        .onPreferenceChange(TutorialFrameKey.self) { frame in
            if tutorialManager.isActive && tutorialManager.currentStepIndex == 8 && tutorialManager.currentStep?.targetView == .paymentMethods && frame != .zero {
                DispatchQueue.main.async {
                    let adjustedFrame = CGRect(
                        x: frame.minX,
                        y: frame.minY - 60,
                        width: frame.width,
                        height: frame.height
                    )
                    tutorialManager.spotlightFrame = adjustedFrame
                }
            }
        }
    }

    private var zelleStatusText: String {
        if appState.profile.zelleQRCode != nil && appState.profile.zellePaymentLink != nil {
            return "QR uploaded • payment link extracted"
        }
        if appState.profile.zelleQRCode != nil {
            return "QR uploaded"
        }
        return "Upload Zelle QR code"
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(color.opacity(0.10))
            .cornerRadius(2)
    }

    private func setupChip(title: String, isDone: Bool, action: (() -> Void)?) -> some View {
        Button(action: {
            HapticManager.impact(style: .light)
            action?()
        }) {
            HStack(spacing: 6) {
                if isDone {
                    VerifiedSealIcon(size: 12, color: Color(red: 0.18, green: 0.50, blue: 0.32))
                }
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundColor(isDone ? Color(red: 0.18, green: 0.50, blue: 0.32) : ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(isDone ? Color(red: 0.87, green: 0.95, blue: 0.90) : Color.white.opacity(0.7))
            .cornerRadius(2)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isDone ? Color(red: 0.18, green: 0.50, blue: 0.32).opacity(0.25) : ink.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(action == nil ? ScaleButtonStyle(scale: 1.0) : ScaleButtonStyle(scale: 0.96))
        .disabled(action == nil)
    }
    

    // FIX 2: Zelle editing state
    @State private var isEditingZelle = false

    // FIX 2: Inline Zelle phone number editor (replaces QR management row)
    private var zelleEditInline: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ZELLE QR CODE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(1)

                if let qrData = appState.profile.zelleQRCode,
                   let qrImage = UIImage(data: qrData) {

                    HStack(spacing: 12) {
                        Image(uiImage: qrImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                            .cornerRadius(2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(ink.opacity(0.2), lineWidth: 1)
                            )

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Zelle QR")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(ink)

                            HStack(spacing: 6) {
                                statusPill("QR UPLOADED", color: Color(red: 0.18, green: 0.50, blue: 0.32))
                                if appState.profile.zellePaymentLink != nil {
                                    statusPill("LINK EXTRACTED", color: Color(red: 0.18, green: 0.50, blue: 0.32))
                                }
                            }
                            .lineLimit(1)
                        }

                        Spacer()

                        HStack(spacing: 12) {
                            Button(action: {
                                showingQRPicker = true
                            }) {
                                Text("Replace")
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .foregroundColor(ink)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.white)
                                    .cornerRadius(2)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(ink.opacity(0.3), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(ScaleButtonStyle(scale: 0.95))

                            Button(action: {
                                HapticManager.notification(type: .warning)
                                withAnimation {
                                    appState.profile.zelleQRCode = nil
                                    appState.profile.zellePaymentLink = nil
                                }
                            }) {
                                TrashIcon(size: 14, color: .red)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(ScaleButtonStyle(scale: 0.95))
                        }
                    }
                    .padding(12)
                    .background(ivory)
                    .cornerRadius(2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(ink.opacity(0.22), lineWidth: 1)
                    )

                } else {
                    Button(action: {
                        showingQRPicker = true
                    }) {
                        HStack(spacing: 10) {
                            ZelleIcon(size: 20, color: .secondary)

                            Text("Upload Zelle QR code")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)

                            Spacer()

                            PlusCircleIcon(size: 20)
                        }
                        .contentShape(Rectangle())
                        .padding(14)
                        .background(Color.white)
                        .cornerRadius(2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(ink.opacity(0.2), lineWidth: 1)
                        )
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isEditingZelle = false
                    }
                    HapticManager.impact(style: .light)
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ink)
            }
        }
        .photosPicker(
            isPresented: $showingQRPicker,
            selection: $selectedQRCodeItem,
            matching: .images
        )
    }
    // FIX 3: zelleQRManagementRow — fixed "Replace" button text wrapping
    private var zelleQRManagementRow: some View {
        HStack(spacing: 12) {
            if let qrData = appState.profile.zelleQRCode, let qrImage = UIImage(data: qrData) {
                Image(uiImage: qrImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .cornerRadius(2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(ink.opacity(0.2), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("QR Code")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ink)
                if appState.profile.zellePaymentLink != nil {
                    Text("Payment link active")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.green)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                // FIX 3: lineLimit(1) + fixedSize prevent text wrapping on "Replace"
                Button(action: { showingQRPicker = true }) {
                    Text("Replace")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundColor(ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white)
                        .cornerRadius(2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(ink.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.95))

                Button(action: {
                    HapticManager.notification(type: .warning)
                    withAnimation {
                        appState.profile.zelleQRCode = nil
                        appState.profile.zellePaymentLink = nil
                    }
                }) {
                    TrashIcon(size: 14, color: .red)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.95))
            }
        }
        .padding(12)
        .background(Color.white)
        .cornerRadius(2)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(ink.opacity(0.2), lineWidth: 1)
        )
    }

    private func paymentStatusRow(
        iconView: AnyView,
        title: String,
        subtitle: String,
        isDone: Bool,
        action: (() -> Void)?
    ) -> some View {
        Button(action: { HapticManager.impact(style: .light); action?() }) {
            HStack(spacing: 16) {
                iconView
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(ink)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isDone {
                    Canvas { ctx, s in
                        let circle = Path(ellipseIn: CGRect(x: 1, y: 1, width: s.width - 2, height: s.height - 2))
                        ctx.fill(circle, with: .color(Color.green))
                        var check = Path()
                        check.move(to:    CGPoint(x: s.width * 0.27, y: s.height * 0.52))
                        check.addLine(to: CGPoint(x: s.width * 0.45, y: s.height * 0.68))
                        check.addLine(to: CGPoint(x: s.width * 0.73, y: s.height * 0.35))
                        ctx.stroke(check, with: .color(.white),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
                    .frame(width: 20, height: 20)
                } else if action != nil {
                    ChevronRightProfileIcon(size: 14, color: .secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .buttonStyle(action != nil ? ScaleButtonStyle(scale: 0.98) : ScaleButtonStyle(scale: 1.0))
        .disabled(action == nil)
    }

    private var venmoEditInline: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("@username", text: Binding(
                get: { appState.profile.venmoUsername ?? "" },
                set: {
                    let cleaned = $0.replacingOccurrences(of: "@", with: "")
                    appState.profile.venmoUsername = cleaned.isEmpty ? nil : cleaned
                }
            ))
            .font(.system(size: 15, weight: .medium))
            .autocapitalization(.none)
            .autocorrectionDisabled()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.white)
            .cornerRadius(2)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(ink.opacity(0.2), lineWidth: 1)
            )

            HStack {
                Spacer()
                Button("Done") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isEditingVenmo = false
                    }
                    HapticManager.impact(style: .light)
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ink)
            }
        }
    }

    // MARK: - Profile Card
    // FIX 2: Removed Zelle QR Code section from Profile card (moved to Get Paid).
    // Phone number field remains but is display-only; editing happens in Get Paid.

    private var profileCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Profile")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(ink)
                Spacer()
                Button(isEditingProfile ? "Done" : "Edit") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isEditingProfile.toggle()
                    }
                    HapticManager.impact(style: .light)
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ink)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Rectangle()
                .fill(ink)
                .frame(height: 1.5)
                .padding(.horizontal, 20)

            if isEditingProfile {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NAME")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .tracking(1)
                        TextField("Your name", text: $appState.profile.name)
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color.white)
                            .cornerRadius(2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(ink.opacity(0.2), lineWidth: 1)
                            )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("PHONE NUMBER")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                                .tracking(1)
                            Spacer()
                            if isPhoneVerified {
                                HStack(spacing: 4) {
                                    VerifiedSealIcon(size: 12, color: .green)
                                    Text("Verified")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.green)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(2)
                            }
                        }

                        // Display-only in Profile; editing is in Get Paid → Zelle row
                        HStack(spacing: 8) {
                            Text(appState.profile.zelleContactInfo ?? "Add in Get Paid section")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(appState.profile.zelleContactInfo == nil ? .secondary : ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.6))
                                .cornerRadius(2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(ink.opacity(0.1), lineWidth: 1)
                                )

                            if !isPhoneVerified {
                                Button(action: {
                                    HapticManager.impact(style: .medium)
                                    showPhoneVerification = true
                                }) {
                                    Text("Verify")
                                        .font(.system(size: 13, weight: .bold))
                                        .tracking(0.5)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 12)
                                        .background(ink)
                                        .cornerRadius(2)
                                }
                                .buttonStyle(ScaleButtonStyle())
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                VStack(spacing: 0) {
                    profileSummaryRow(
                        iconView: AnyView(ProfilePersonIcon(size: 18, color: .secondary)),
                        value: appState.profile.name.isEmpty ? "Set your name" : appState.profile.name,
                        isEmpty: appState.profile.name.isEmpty
                    )
                    Rectangle()
                        .fill(ink.opacity(0.2))
                        .frame(height: 1)
                        .padding(.leading, 56)
                    profileSummaryRow(
                        iconView: AnyView(PhoneProfileIcon(size: 18, color: .secondary)),
                        value: {
                            if let phone = appState.profile.zelleContactInfo, !phone.isEmpty { return phone }
                            return "No phone number"
                        }(),
                        badge: isPhoneVerified ? "Verified" : nil,
                        badgeColor: .green,
                        isEmpty: appState.profile.zelleContactInfo == nil
                    )
                }
                .padding(.bottom, 4)
            }
        }
        .background(chalk)
        .cornerRadius(2)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(ink, lineWidth: 1.5)
        )
    }

    private func profileSummaryRow(
        iconView: AnyView,
        value: String,
        badge: String? = nil,
        badgeColor: Color = .green,
        isEmpty: Bool = false
    ) -> some View {
        HStack(spacing: 16) {
            iconView
                .frame(width: 36)

            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(isEmpty ? .secondary : ink)

            Spacer()

            if let badge = badge {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(badgeColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(badgeColor.opacity(0.1))
                    .cornerRadius(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Pro Trial Card

    private var proTrialCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dutch Pro")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(ink)
                    Text(proTrialStatusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: trialManager.hasActiveSubscription ? "checkmark.seal.fill" : (trialManager.isTrialActive ? "sparkles" : "lock.open"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(ink)
            }

            HStack(spacing: 10) {
                proTrialStat(value: trialManager.receiptOCRAllowanceText, label: trialManager.hasActiveSubscription ? "Scan limit" : "Scans left")
                proTrialStat(value: trialManager.hasActiveSubscription ? "Active" : "\(trialManager.daysRemaining)", label: trialManager.hasActiveSubscription ? "Pro" : "Days left")
            }

            if let group = cachedSubscriptionInviteGroup, group.maxMemberCount != nil {
                let planLimit = cachedPlanLimit ?? group.maxMemberCount ?? group.members.count
                let planRoster = cachedPlanRoster
                let occupiedPlanCount = min(planRoster.count, planLimit)
                VStack(alignment: .leading, spacing: 10) {
                    Text(planSeatStatusText(roster: planRoster, planLimit: planLimit))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(occupiedPlanCount >= planLimit ? .green : .orange)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("People on this plan")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.8)
                            .foregroundColor(ink.opacity(0.55))

                        if planRoster.isEmpty {
                            Text("No one is in this plan yet")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(planRoster) { member in
                                subscriptionPlanMemberRow(member, group: group, allowRemoval: true)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.45))
                    .cornerRadius(6)

                    if occupiedPlanCount >= planLimit {
                        Text("Invite link closed")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.62))
                            .cornerRadius(6)
                    } else {
                        Text(group.inviteLink)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(ink.opacity(0.72))
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.62))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(ink.opacity(0.1), lineWidth: 1)
                            )

                        HStack(spacing: 10) {
                            ShareLink(item: profileInviteMessage(for: group)) {
                                Text("SHARE")
                                    .font(.system(size: 12, weight: .bold))
                                    .tracking(1)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(ink)
                                    .cornerRadius(2)
                            }
                            .buttonStyle(ScaleButtonStyle(scale: 0.97))

                            Button {
                                UIPasteboard.general.string = group.inviteLink
                                HapticManager.notification(type: .success)
                            } label: {
                                Text("COPY")
                                    .font(.system(size: 12, weight: .bold))
                                    .tracking(1)
                                    .foregroundColor(ink)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.white.opacity(0.7))
                                    .cornerRadius(2)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(ink.opacity(0.25), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(ScaleButtonStyle(scale: 0.97))
                        }
                    }
                }
            }

            if !trialManager.hasStartedTrial && !trialManager.hasScheduledSubscription {
                Button {
                    HapticManager.impact(style: .medium)
                    guard networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to start or manage Dutch Pro.") else {
                        return
                    }
                    paywallConfig = PaywallSheetConfig(startsPaidImmediately: trialManager.hasStartedTrial, opensSubscriptionInvite: false)
                } label: {
                    Text(proTrialButtonTitle)
                        .font(.system(size: 13, weight: .bold))
                        .tracking(1)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(ink)
                        .cornerRadius(2)
                }
                .buttonStyle(ScaleButtonStyle())
            }

            if trialManager.hasScheduledSubscription || trialManager.hasSharedSubscriptionAccess || trialManager.isTrialExpired {
                Button {
                    HapticManager.impact(style: .light)
                    paywallConfig = PaywallSheetConfig(
                        startsPaidImmediately: true,
                        opensSubscriptionInvite: false,
                        managedSubscriptionGroupID: cachedManagedSubscriptionGroupID
                    )
                } label: {
                    Text("CANCEL OR MANAGE SUBSCRIPTION")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.72))
                        .cornerRadius(2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(ink.opacity(0.22), lineWidth: 1)
                        )
                }
                .buttonStyle(ScaleButtonStyle())

                Button {
                    HapticManager.impact(style: .light)
                    subscriptionPeopleManagerConfig = SubscriptionPeopleManagerConfig(
                        managedSubscriptionGroupID: cachedManagedSubscriptionGroupID
                    )
                } label: {
                    Text("CHANGE PLAN OR PEOPLE")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.72))
                        .cornerRadius(2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(ink.opacity(0.22), lineWidth: 1)
                        )
                }
                .buttonStyle(ScaleButtonStyle())

                Text("Canceling keeps Dutch Pro through the current \(subscriptionPeriodLabel).")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .background(chalk)
        .cornerRadius(2)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(ink, lineWidth: 1.5)
        )
    }

    private var proTrialStatusText: String {
        if trialManager.hasSharedSubscriptionAccess &&
            trialManager.subscriptionPlanName == "Shared Dutch Pro" {
            let groupName = trialManager.sharedSubscriptionGroupName ?? subscriptionInviteGroup?.name ?? "your group"
            return "Shared Dutch Pro is active through \(groupName). You have access through this subscription group."
        }
        if trialManager.hasActiveSubscription {
            let plan = trialManager.subscriptionPlanName ?? "Dutch Pro"
            if let remaining = trialManager.subscriptionOCRSessionsRemaining,
               let limit = trialManager.subscriptionOCRSessionLimit {
                return "\(plan) is active. \(remaining) of \(limit) scan credits left in this plan period."
            }
            return "\(plan) is active. Your scan limit is now \(trialManager.subscriptionScanAllowance ?? "your Pro plan")."
        }
        if trialManager.isTrialExpired {
            return "Your 3-day trial ended. Choose a credit pack or group pass to keep scanning."
        }
        if trialManager.isTrialActive {
            if trialManager.hasScheduledSubscription {
                return "Trial active. You have 20 scan credits total for 3 days. Your plan renews automatically after the trial unless you cancel."
            }
            return "\(trialManager.daysRemaining) day\(trialManager.daysRemaining == 1 ? "" : "s") left. Start Pro now to begin the paid plan today, or wait until the trial ends."
        }
        return "Start a 3-day trial with 20 scan credits. Apple will charge automatically after the trial unless you cancel."
    }

    private var proTrialButtonTitle: String {
        if trialManager.isTrialExpired { return "CHOOSE PLAN" }
        if trialManager.isTrialActive { return "MANAGE TRIAL" }
        return "START 3-DAY TRIAL"
    }

    private var subscriptionPeriodLabel: String {
        let name = (trialManager.subscriptionPlanName ?? "").lowercased()
        if name.contains("week") { return "week" }
        if name.contains("year") { return "year" }
        return "month"
    }

    private func openSubscriptionManagement() {
        guard networkMonitor.requireOnline(message: "Turn on Wi-Fi or cellular data to manage your subscription.") else {
            return
        }
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        UIApplication.shared.open(url)
    }

    private func openProPlanManagement() {
        subscriptionPeopleManagerConfig = SubscriptionPeopleManagerConfig(
            managedSubscriptionGroupID: cachedManagedSubscriptionGroupID
        )
    }

    private func proTrialStat(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.55))
        .cornerRadius(6)
    }

    private func planSeatStatusText(roster: [GroupMember], planLimit: Int) -> String {
        let used = min(roster.count, planLimit)
        let joined = roster.filter { !$0.hasLeft && !$0.isPending }.count
        let invited = roster.filter { !$0.hasLeft && $0.isPending }.count
        var parts = ["\(used)/\(planLimit) plan seats used", "\(joined) joined"]
        if invited > 0 {
            parts.append("\(invited) invited · not joined")
        }
        return parts.joined(separator: " · ")
    }

    private func subscriptionPlanMemberRow(_ member: SubscriptionPlanMember) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ink)
                .frame(width: 30, height: 30)
                .overlay(
                    Text(member.initials)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(chalk)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(member.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ink)
                    .lineLimit(1)
                Text(member.isOwner ? "Owner" : (member.isPending ? "Invited · not joined" : "Joined"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(member.isOwner ? .secondary : (member.isPending ? .orange : .green))
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func subscriptionPlanMemberRow(_ member: GroupMember, group: DutchieGroup, allowRemoval: Bool = true) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ink)
                .frame(width: 30, height: 30)
                .overlay(
                    Text(member.initials)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(chalk)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(subscriptionMemberDisplayName(member, in: group))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ink)
                    .lineLimit(1)
                Text(member.isPending ? "Invited · not joined" : "Joined")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(member.isPending ? .orange : .green)
            }

            Spacer()

            if allowRemoval && currentUserOwnsSubscriptionGroup(group), member.isPending, !member.isCurrentUser {
                Button {
                    HapticManager.impact(style: .light)
                    deferProfileAction {
                        groupManager.removePendingInvitedMember(groupID: group.id, memberID: member.id)
                        refreshProfileRenderCache()
                    }
                } label: {
                    Text("REMOVE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundColor(ink)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.75))
                        .cornerRadius(2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(ink.opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func subscriptionMemberDisplayName(_ member: GroupMember, in group: DutchieGroup) -> String {
        let trimmed = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Member" : trimmed
        if member.isCurrentUser {
            return baseName.localizedCaseInsensitiveCompare("You") == .orderedSame ? "You (Me)" : "\(baseName) (You)"
        }
        if baseName.localizedCaseInsensitiveCompare("You") == .orderedSame {
            if group.createdByID == member.id { return "Plan owner" }
            if let phone = member.phoneNumber?.filter(\.isNumber), phone.count >= 4 {
                return "Member \(phone.suffix(4))"
            }
            return "Member"
        }
        return baseName
    }

    private func currentUserOwnsSubscriptionGroup(_ group: DutchieGroup) -> Bool {
        !trialManager.hasSharedSubscriptionAccess && trialManager.ownedSubscriptionGroupID == group.id
    }

    private func profileInviteMessage(for group: DutchieGroup) -> String {
        """
        Join my Dutch subscription group "\(group.name)".

        Dutch invite link (full link):
        \(group.inviteLink)
        """
    }

    // MARK: - History Card

    private var historyCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(ink)
                Spacer()
                if !appState.profile.splitHistory.isEmpty {
                    Button(action: {
                        HapticManager.impact(style: .light)
                        showHistoryBrowser = true
                    }) {
                        Text("See all")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(ink)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Rectangle()
                .fill(ink)
                .frame(height: 1.5)
                .padding(.horizontal, 20)

            if appState.profile.splitHistory.isEmpty {
                VStack(spacing: 8) {
                    Text("No splits yet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(ink)
                    Text("Your past splits will appear here")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                VStack(spacing: 0) {
                    let records = Array(filteredHistory.prefix(3))

                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 {
                            Rectangle()
                                .fill(ink.opacity(0.2))
                                .frame(height: 1)
                                .padding(.leading, 20)
                        }
                        compactHistoryRow(record: record)
                    }

                    if !isExpandingHistory && appState.profile.splitHistory.count > 3 {
                        Rectangle()
                            .fill(ink)
                            .frame(height: 1.5)
                            .padding(.horizontal, 20)
                        Button(action: {
                            HapticManager.impact(style: .light)
                            showHistoryBrowser = true
                        }) {
                            Text("+ \(appState.profile.splitHistory.count - 3) MORE")
                                .font(.system(size: 13, weight: .semibold))
                                .tracking(0.5)
                                .foregroundColor(ink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(ScaleButtonStyle(scale: 0.98))
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .background(chalk)
        .cornerRadius(2)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(ink, lineWidth: 1.5)
        )
    }

    private func compactHistoryRow(record: SplitRecord) -> some View {
        Button(action: {
            HapticManager.impact(style: .light)
            selectedHistoryRecord = record
        }) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    if let groupName = record.groupName, !groupName.isEmpty {
                        Text(groupName.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(ink.opacity(0.55))
                            .tracking(1.2)
                    }
                    Text(record.formattedTotal)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(ink)
                    Text("\(record.formattedDate) · \(record.participantCount) people · \(record.transactionCount) transaction\(record.transactionCount == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(record.yourBalance == 0 ? "Settled" : record.formattedBalance)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(record.yourBalance >= 0 ? .green : .red)
                    Text(record.yourBalance > 0 ? "owed to you" : record.yourBalance < 0 ? "you owed" : "")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
    }


    
    // MARK: - Sign Out Row

    @ViewBuilder
    private var developerPanelButton: some View {
        Button {
            HapticManager.impact(style: .medium)
            showDeveloperPanel = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("Developer Mode")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(Color(red: 0.11, green: 0.10, blue: 0.08).opacity(0.4))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(ScaleButtonStyle())
        .sheet(isPresented: $showDeveloperPanel) {
            DeveloperPanel().environmentObject(appState)
        }
    }

    @ViewBuilder private var signOutRow: some View {
        if authManager.isAuthenticated {
            VStack(spacing: 8) {
                Button(action: {
                    HapticManager.impact(style: .medium)
                    deferProfileAction {
                        signOut()
                    }
                }) {
                    Text("Sign out")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.97))

                Button(role: .destructive) {
                    HapticManager.impact(style: .medium)
                    showDeleteAccountAlert = true
                } label: {
                    Text("Delete account")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.97))
            }
        }
    }

    // MARK: - Sheet Contents

    @ViewBuilder
    private var groupJoinSheetContent: some View {
        if let invite = pendingInvite {
            GroupJoinView(groupManager: groupManager, invite: invite, onJoinComplete: {
                pendingInvite = nil
                showGroupJoin = false
                groupManager.pendingInvite = nil
                groupManager.objectWillChange.send()
            })
            .environmentObject(authManager)
            .environmentObject(appState)
        }
    }

    @ViewBuilder
    private var groupNameSheetContent: some View {
        GroupNameSheet(isPresented: $showGroupNameSheet) { groupName in
            deferProfileAction {
                createNewGroup(named: groupName)
                refreshProfileRenderCache()
            }
        }
    }

    @ViewBuilder
    private var tutorialOverlayIfNeeded: some View {
        if tutorialManager.isActive && tutorialManager.isCurrentStep(in: .profile) {
            ProfileTutorialOverlay(
                onNext: {
                    tutorialManager.nextStep()
                },
                paywallConfig: $paywallConfig,
                onSkip: {
                    tutorialManager.skip()
                }
            )
            .environmentObject(tutorialManager)
        }
    }

    @ViewBuilder
    private var joinBannerIfNeeded: some View {
        if showJoinBanner {
            VStack {
                GroupJoinBannerView(
                    memberName: joinedMemberName,
                    groupName: joinedGroupName,
                    isLastMember: isLastJoinedMember,
                    isVisible: $showJoinBanner,
                    onTap: {
                        if let group = groupManager.currentUserAvailableGroups.first(where: { $0.name == joinedGroupName }) {
                            activateGroupAndNavigate(group)
                        }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.top, 70)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1000)
                Spacer()
            }
        }
    }

    private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: {
                HapticManager.impact(style: .light)
                if tutorialManager.isActive && tutorialManager.currentStepIndex == 2 {
                    router.dismissProfile()
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { tutorialManager.nextStep() }
                } else {
                    router.dismissProfile()
                    dismiss()
                }
            }) {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.08)).frame(width: 32, height: 32)
                    XMarkProfileIcon(size: 13, color: Color(.label).opacity(0.7))
                }
            }
            .buttonStyle(ScaleButtonStyle())
        }
    }

    // MARK: - Helpers

    private func activateGroupAndNavigate(_ group: DutchieGroup) {
        guard authManager.canUseGroupMode else {
            showPhoneVerification = true
            return
        }

        HapticManager.impact(style: .medium)
        dismiss()
        deferProfileAction(after: 0.04) {
            groupManager.setActiveGroup(group)
            groupManager.enableGroupMode()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            router.navigateToSettle()
        }
    }

    private func handleQRCodeSelection(_ item: PhotosPickerItem?) async {
        guard let data = try? await item?.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }

        if let extractedLink = QRCodeScanner.extractPaymentLink(from: image) {
            let isValid = QRCodeScanner.validateZelleQRLink(extractedLink)
            if isValid {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    appState.profile.zelleQRCode = data
                    appState.profile.zellePaymentLink = extractedLink
                }
                HapticManager.notification(type: .success)
            } else {
                qrScanErrorMessage = "This doesn't appear to be a valid Zelle QR code."
                showQRScanError = true
                HapticManager.notification(type: .error)
            }
        } else {
            qrScanErrorMessage = "Unable to scan QR code. Make sure the image is clear and fully visible."
            showQRScanError = true
            HapticManager.notification(type: .error)
        }
    }

    private func syncPaymentInfo() {
        groupManager.syncCurrentUserPaymentInfo(from: appState.profile)
        authManager.syncVerifiedUserProfile(from: appState)
        notificationManager.schedulePaymentSetupReminders(profile: appState.profile)
    }

    private func schedulePaymentInfoSync() {
        paymentSyncWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            syncPaymentInfo()
        }
        paymentSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: workItem)
    }

    private func deferProfileAction(after delay: TimeInterval = 0.05, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let start = CFAbsoluteTimeGetCurrent()
            work()
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            if elapsedMs > 16 {
                print("🧭 PERF [profile:tap-action] ms=\(elapsedMs)")
            }
        }
    }

    private func createNewGroup(named groupName: String) {
        let currentUser = appState.people.first(where: { $0.isCurrentUser })
        let venmoUsername = appState.profile.venmoUsername?
            .replacingOccurrences(of: "@", with: "")
            .trimmingCharacters(in: .whitespaces)
        let zelleContact = appState.profile.zelleContactInfo?.trimmingCharacters(in: .whitespaces)

        let member = GroupMember(
            id: currentUser?.id ?? UUID(),
            name: currentUser?.name ?? appState.profile.name,
            phoneNumber: currentUser?.phoneNumber ?? zelleContact,
            imageData: currentUser?.contactImage ?? appState.profile.avatarImage,
            isCurrentUser: true,
            venmoUsername: venmoUsername,
            venmoLink: appState.profile.venmoPaymentLink,
            zelleEmail: zelleContact,
            zelleLink: appState.profile.zellePaymentLink
        )
        groupManager.createFreshGroup(name: groupName, members: [member])
    }

    private func signOut() {
        do {
            try authManager.signOut()
            appState.profile.zelleContactInfo = nil
            HapticManager.notification(type: .success)
            dismiss()
        } catch {
            print("❌ Sign out error: \(error.localizedDescription)")
            HapticManager.notification(type: .error)
        }
    }

    private func deleteAccount() {
        authManager.deleteCurrentAccount { result in
            switch result {
            case .success:
                HapticManager.notification(type: .success)
                dismiss()
            case .failure(let error):
                deleteAccountErrorMessage = error.localizedDescription
                showDeleteAccountError = true
                HapticManager.notification(type: .error)
            }
        }
    }

    private func setupOnAppear() {
        didDeferHeavyProfileSections = false
        if tutorialManager.isActive && (tutorialManager.currentStepIndex == 2 || tutorialManager.currentStepIndex == 7) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    scrollProxy?.scrollTo("paymentSection", anchor: .center)
                }
            }
        }
        setupNotificationObservers()
        scheduleProfileRenderCache(reason: "appear", after: 0.08) {
            didDeferHeavyProfileSections = true
        }
        deferProfileAction(after: 1.0) {
            refreshSharedSubscriptionGroup(groupID: trialManager.sharedSubscriptionGroupID ?? subscriptionInviteGroup?.id)
            if !trialManager.hasSharedSubscriptionAccess,
               let group = subscriptionInviteGroup,
               trialManager.ownedSubscriptionGroupID == group.id,
               group.maxMemberCount != nil {
                let phoneKey = authManager.phoneNumber ?? appState.profile.zelleContactInfo ?? ""
                let syncKey = "\(group.id.uuidString):owner:\(appState.profile.name):\(phoneKey)"
                if lastSubscriptionMemberSyncKey != syncKey {
                    lastSubscriptionMemberSyncKey = syncKey
                    trialManager.activateOwnedSubscriptionGroup(groupID: group.id, groupName: group.name)
                    trialManager.syncCurrentSubscriptionMember(profile: appState.profile, groupID: group.id, groupName: group.name, isOwner: true)
                }
            } else if trialManager.hasSharedSubscriptionAccess,
                      let group = subscriptionInviteGroup {
                let phoneKey = authManager.phoneNumber ?? appState.profile.zelleContactInfo ?? ""
                let syncKey = "\(group.id.uuidString):shared:\(appState.profile.name):\(phoneKey)"
                if lastSubscriptionMemberSyncKey != syncKey {
                    lastSubscriptionMemberSyncKey = syncKey
                    trialManager.syncCurrentSubscriptionMember(profile: appState.profile, groupID: group.id, groupName: group.name, isOwner: false)
                }
            }
            notificationManager.schedulePaymentSetupReminders(profile: appState.profile)
        }
    }

    private func scheduleProfileRenderCache(
        reason: String,
        after delay: TimeInterval = 0.18,
        completion: (() -> Void)? = nil
    ) {
        profileRenderWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            let start = CFAbsoluteTimeGetCurrent()
            refreshProfileRenderCache()
            completion?()
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            if elapsedMs > 16 {
                print("🧭 PERF [profile:scheduled-cache] reason=\(reason) ms=\(elapsedMs)")
            }
        }
        profileRenderWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func refreshProfileRenderCache() {
        let start = CFAbsoluteTimeGetCurrent()
        let group = subscriptionInviteGroup
        cachedSubscriptionInviteGroup = group

        guard let group, group.maxMemberCount != nil else {
            cachedPlanRoster = []
            cachedPlanLimit = nil
            return
        }

        let planLimit = trialManager.hasSharedSubscriptionAccess
            ? (group.maxMemberCount ?? max(1, group.occupiedMemberCount))
            : (trialManager.subscriptionMemberLimit ?? group.maxMemberCount ?? group.members.count)
        cachedPlanLimit = planLimit
        cachedPlanRoster = groupManager.subscriptionPlanRosterMembers(
            profile: appState.profile,
            currentPerson: appState.people.first(where: { $0.isCurrentUser }),
            including: group,
            hydrateContacts: false
        )

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        if elapsedMs > 16 {
            print("🧭 PERF [profile:render-cache] roster=\(cachedPlanRoster.count) limit=\(planLimit) ms=\(elapsedMs)")
        }
    }

    private func refreshSharedSubscriptionGroup(groupID: UUID?) {
        guard let groupID else {
            resolvedSharedSubscriptionGroup = nil
            return
        }

        groupManager.refreshGroupFromFirebase(groupID: groupID) { group in
            guard let group else { return }

            DispatchQueue.main.async {
                if trialManager.sharedSubscriptionGroupID == group.id {
                    resolvedSharedSubscriptionGroup = group
                    groupManager.ensureSubscriptionGroupVisible(
                        groupID: group.id,
                        groupName: group.name,
                        profile: appState.profile
                    )
                    let ownerPhone = group.members.first(where: { $0.id == group.createdByID })?.phoneNumber
                    trialManager.refreshSharedSubscriptionMetadata(
                        groupID: group.id,
                        groupName: group.name,
                        ownerPhone: ownerPhone
                    )
                }
            }
        }
    }

    private func setupNotificationObservers() {
        guard notificationObserverTokens.isEmpty else {
            return
        }

        let deepLinkToken = NotificationCenter.default.addObserver(forName: .processDeepLink, object: nil, queue: .main) { notification in
            guard notification.userInfo?["invite"] is PendingGroupInvite else { return }
            pendingInvite = nil
            showGroupJoin = false
        }
        let paymentSetupToken = NotificationCenter.default.addObserver(forName: .openPaymentSetup, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    scrollProxy?.scrollTo("paymentSection", anchor: .center)
                }
            }
        }
        let joinBannerToken = NotificationCenter.default.addObserver(forName: .showGroupJoinBanner, object: nil, queue: .main) { notification in
            guard let info = notification.userInfo,
                  let name = info["memberName"] as? String,
                  let group = info["groupName"] as? String,
                  let isLast = info["isLastMember"] as? Bool else { return }
            joinedMemberName = name
            joinedGroupName = group
            isLastJoinedMember = isLast
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showJoinBanner = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation(.spring(response: 0.3)) { showJoinBanner = false }
            }
        }

        notificationObserverTokens = [deepLinkToken, paymentSetupToken, joinBannerToken]
    }

    private func tearDownNotificationObservers() {
        notificationObserverTokens.forEach(NotificationCenter.default.removeObserver)
        notificationObserverTokens = []
    }
    
    // MARK: - Profile Tutorial Overlay
    struct ProfileTutorialOverlay: View {
        @EnvironmentObject var tutorialManager: TutorialManager
        let onNext: () -> Void
        @Binding var paywallConfig: PaywallSheetConfig?
        let onSkip: () -> Void
        
        // Match ProfileView colors
        private let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)
        private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)
        private let chalk = Color(red: 0.96, green: 0.96, blue: 0.94)

        var body: some View {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    if tutorialManager.isActive,
                       let step = tutorialManager.currentStep,
                       tutorialManager.isCurrentStep(in: .profile) {
                        
                        // Always show overlay with cutout for step 8
                        Color.clear
                            .contentShape(Rectangle())
                            .allowsHitTesting(true)
                            .zIndex(0)

                        overlayWithCutout(step: step)
                            .allowsHitTesting(true)
                            .zIndex(1)
                        
                        tutorialCardPositioned(step: step, in: geometry)
                            .zIndex(3)
                    }
                }
            }
            .ignoresSafeArea()
        }
        
        @ViewBuilder
        private func tutorialCardPositioned(step: TutorialStep, in geometry: GeometryProxy) -> some View {
            let sf = tutorialManager.spotlightFrame
            let screenHeight = geometry.size.height
            let inBottomHalf = sf != .zero && sf.midY > screenHeight / 2
            
            // For payment methods (step 8), always show at bottom
            if step.targetView == .paymentMethods || (!inBottomHalf && sf != .zero) {
                VStack {
                    Spacer()
                    tutorialCard(step: step)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 44)
                }
            } else {
                VStack {
                    tutorialCard(step: step)
                        .padding(.horizontal, 20)
                        .padding(.top, 60)
                    Spacer()
                }
            }
        }

        private func overlayWithCutout(step: TutorialStep) -> some View {
            let pad: CGFloat = step.targetView == .paymentMethods ? 16 : 12
            
            let frame = tutorialManager.spotlightFrame
            let hasHole = frame != .zero && step.targetView != .fullScreen
            let cutout = hasHole
                ? CGRect(
                    x: frame.minX - pad,
                    y: frame.minY - pad,
                    width: frame.width + pad * 2,
                    height: frame.height + pad * 2
                  )
                : .zero

            return Color.black.opacity(0.75)
                .ignoresSafeArea()
                .mask(SpotlightMask(cutoutRect: cutout, cornerRadius: 18))
        }
        
        
        private func tutorialCard(step: TutorialStep) -> some View {
            VStack(spacing: 16) {
                // Progress bar
                HStack(spacing: 6) {
                    ForEach(0..<tutorialManager.totalSteps, id: \.self) { index in
                        Capsule()
                            .fill(index <= tutorialManager.currentStepIndex
                                  ? ink : ink.opacity(0.18))
                            .frame(height: 4)
                            .frame(maxWidth: .infinity)
                    }
                }

                Text(step.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Text(step.description)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(ink.opacity(0.88))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    if tutorialManager.isLastStep {
                        Button(action: {
                            HapticManager.notification(type: .success)
                            tutorialManager.complete()
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                paywallConfig = PaywallSheetConfig(startsPaidImmediately: false, opensSubscriptionInvite: false)
                            }
                        }) {
                            HStack(spacing: 8) {
                                Text("Get Started").font(.system(size: 15, weight: .bold))
                                Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(ink)
                            .cornerRadius(12)
                            .shadow(color: ink.opacity(0.3), radius: 8, y: 4)
                        }
                        .buttonStyle(ScaleButtonStyle())
                    
                    } else {
                        Button(action: {
                            HapticManager.impact(style: .light)
                            tutorialManager.skip()
                        }) {
                            Text("Skip")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(ink.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(chalk)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(ink.opacity(0.2), lineWidth: 1)
                                )
                        }
                        .buttonStyle(ScaleButtonStyle())

                        Button(action: {
                            HapticManager.impact(style: .medium)
                            onNext()
                        }) {
                            HStack(spacing: 6) {
                                Text("Next")
                                    .font(.system(size: 14, weight: .bold))
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(ink)
                            .cornerRadius(12)
                            .shadow(color: ink.opacity(0.3), radius: 8, y: 4)
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                }

                Text("\(tutorialManager.currentStepIndex + 1) of \(tutorialManager.totalSteps)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ink.opacity(0.5))
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(chalk)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(ink, lineWidth: 1.5)
                    )
                    .shadow(color: Color.black.opacity(0.2), radius: 20, y: 6)
            )
        }
    }
    
    // MARK: - Split History Card (kept for sheet detail)
struct SplitHistoryCard: View {
        let record: SplitRecord
        let onTap: () -> Void

        var body: some View {
            Button(action: { HapticManager.impact(style: .light); onTap() }) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        if let groupName = record.groupName, !groupName.isEmpty {
                            Text(groupName.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)
                                .tracking(1.2)
                        }
                        Text(record.formattedTotal).font(.system(size: 18, weight: .bold)).foregroundColor(.primary)
                        Text("\(record.formattedDate) · \(record.participantCount) people · \(record.transactionCount) transaction\(record.transactionCount == 1 ? "" : "s")")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(record.yourBalance == 0 ? "Settled" : record.formattedBalance)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(record.yourBalance >= 0 ? .green : .red)
                        Text(record.yourBalance > 0 ? "owed to you" : record.yourBalance < 0 ? "you owed" : "")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                    }
                    ChevronRightProfileIcon(size: 13, color: .secondary)
                }
                .padding(16)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.98))
        }
    }
}

// MARK: - Share Toggle Button
struct ShareToggleButton: View {
    @Binding var isShared: Bool

    var body: some View {
        Button(action: {
            HapticManager.impact(style: .light)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isShared.toggle() }
        }) {
            HStack(spacing: 5) {
                if isShared {
                    ZStack {
                        Ellipse().stroke(Color.green, lineWidth: 1.5).frame(width: 14, height: 10)
                        Circle().fill(Color.green).frame(width: 4, height: 4)
                    }
                } else {
                    ZStack {
                        Ellipse().stroke(Color.secondary, lineWidth: 1.5).frame(width: 14, height: 10)
                        Path { p in p.move(to: CGPoint(x: 2, y: 2)); p.addLine(to: CGPoint(x: 12, y: 8)) }
                            .stroke(Color.secondary, lineWidth: 1.5)
                    }
                }
                Text(isShared ? "Shared" : "Hidden").font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(isShared ? Color.green : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(isShared ? Color.green.opacity(0.12) : Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isShared ? Color.green.opacity(0.3) : Color.primary.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.95))
    }
}

// MARK: - Split History Browser
struct SplitHistoryBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let records: [SplitRecord]

    @State private var selectedMonthKey = "all"
    @State private var selectedRecord: SplitRecord?
    @State private var searchText = ""

    private let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)
    private let chalk = Color(red: 0.96, green: 0.96, blue: 0.94)

    private var sortedRecords: [SplitRecord] {
        records.sorted { $0.date > $1.date }
    }

    private var monthKeys: [String] {
        var seen: Set<String> = []
        return sortedRecords.compactMap { record in
            let key = monthKey(for: record.date)
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return key
        }
    }

    private var filteredRecords: [SplitRecord] {
        sortedRecords.filter { record in
            let matchesMonth = selectedMonthKey == "all" || monthKey(for: record.date) == selectedMonthKey
            guard matchesMonth else { return false }
            guard !searchText.isEmpty else { return true }
            let q = searchText.lowercased()
            return record.formattedTotal.lowercased().contains(q)
                || record.formattedDate.lowercased().contains(q)
                || (record.groupName?.lowercased().contains(q) ?? false)
                || "\(record.participantCount)".contains(q)
                || (record.transactions ?? []).contains {
                    $0.merchant.lowercased().contains(q)
                        || ($0.assignmentLabel?.lowercased().contains(q) ?? false)
                }
                || record.settlements.contains {
                    $0.fromName.lowercased().contains(q) || $0.toName.lowercased().contains(q)
                }
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                ivory.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    monthRail
                    searchBar

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            ForEach(filteredRecords) { record in
                                historyRow(record)
                            }

                            if filteredRecords.isEmpty {
                                emptyState
                            }
                        }
                        .padding(20)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationBarHidden(true)
        }
        .sheet(item: $selectedRecord) { record in
            NavigationView { SplitHistoryDetailView(record: record) }
                .environmentObject(appState)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Split History")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(ink)
                    Text("\(records.count) saved splits")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    XMarkProfileIcon(size: 14, color: ink)
                        .frame(width: 38, height: 38)
                        .background(chalk)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink, lineWidth: 1.2))
                        .cornerRadius(8)
                }
                .buttonStyle(ScaleButtonStyle(scale: 0.94))
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Rectangle()
                .fill(ink)
                .frame(height: 1.5)
                .padding(.horizontal, 20)
        }
    }

    private var monthRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                monthButton(title: "All", key: "all")
                ForEach(monthKeys, id: \.self) { key in
                    monthButton(title: monthTitle(for: key), key: key)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ink.opacity(0.65))
            TextField("Search amount, date, or person", text: $searchText)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(ink)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(ink.opacity(0.45))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(chalk)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink.opacity(0.18), lineWidth: 1))
        .cornerRadius(8)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    private func monthButton(title: String, key: String) -> some View {
        let isSelected = selectedMonthKey == key
        return Button(action: {
            HapticManager.impact(style: .light)
            selectedMonthKey = key
        }) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(isSelected ? ivory : ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(isSelected ? ink : chalk)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink, lineWidth: isSelected ? 0 : 1))
                .cornerRadius(8)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.96))
    }

    private func historyRow(_ record: SplitRecord) -> some View {
        Button(action: {
            HapticManager.impact(style: .light)
            selectedRecord = record
        }) {
            HStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text(dayMonth(for: record.date).0)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(dayMonth(for: record.date).1)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(ink)
                }
                .frame(width: 42)

                VStack(alignment: .leading, spacing: 5) {
                    if let groupName = record.groupName, !groupName.isEmpty {
                        Text(groupName.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(ink.opacity(0.55))
                            .tracking(1.2)
                    }
                    Text(record.formattedTotal)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(ink)
                    Text("\(record.participantCount) people · \(record.transactionCount) transaction\(record.transactionCount == 1 ? "" : "s") · \(record.formattedTime)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(record.yourBalance == 0 ? "Settled" : record.formattedBalance)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(ivory)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink.opacity(0.16), lineWidth: 1))
                    .cornerRadius(8)
            }
            .padding(14)
            .background(chalk)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink, lineWidth: 1.2))
            .cornerRadius(8)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.98))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No splits here")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(ink)
            Text("Try another month or search.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private func monthKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    private func monthTitle(for key: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        guard let date = formatter.date(from: key) else { return key }
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    private func dayMonth(for date: Date) -> (String, String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        let month = formatter.string(from: date)
        formatter.dateFormat = "dd"
        return (month, formatter.string(from: date))
    }
}

// MARK: - Split History Detail View
struct SplitHistoryDetailView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    let record: SplitRecord

    @State private var remindedSettlements: Set<UUID> = []

    private let ivory = Color(red: 1.0, green: 0.992, blue: 0.969)
    private let ink = Color(red: 0.15, green: 0.15, blue: 0.15)
    private let chalk = Color(red: 0.96, green: 0.96, blue: 0.94)
    private var transactionSnapshots: [TransactionSnapshot] { record.transactions ?? [] }

    private func phoneNumber(for name: String) -> String? {
        PeopleStorageManager.shared.loadRecentPeople().first(where: { $0.name == name })?.phoneNumber
    }

    private var venmoUsername: String? {
        let u = appState.profile.venmoUsername?.replacingOccurrences(of: "@", with: "") ?? ""
        return u.isEmpty ? nil : u
    }
    private var venmoPaymentLink: String? {
        let l = appState.profile.venmoPaymentLink ?? ""; return l.isEmpty ? nil : l
    }
    private var zellePaymentLink: String? {
        let l = appState.profile.zellePaymentLink ?? ""; return l.isEmpty ? nil : l
    }
    private var zelleEmail: String? { appState.profile.zelleContactInfo }

    private func generateZelleDeepLink(amount: Double) -> String? {
        if let link = zellePaymentLink { return link }
        if let email = zelleEmail, email.contains("@"), !email.isEmpty {
            let amt = String(format: "%.2f", amount)
            let encoded = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
            return "zelle://payment?token=\(encoded)&amount=\(amt)"
        }
        return nil
    }

    private var zellePhoneNote: String? {
        guard let c = zelleEmail, !c.isEmpty, !c.contains("@") else { return nil }
        return "Zelle: Send to \(c) via your bank app or the Zelle app"
    }

    private func reminderMessage(for settlement: SettlementSnapshot) -> String {
        var text = "Hey \(settlement.fromName), just a reminder that you owe \(settlement.toName) \(settlement.formattedAmount) from our recent split.\n\nPayment Summary\n\(settlement.fromName) -> \(settlement.toName): \(settlement.formattedAmount)\n\n"
        var lines: [String] = []
        if let u = venmoUsername {
            let amt = String(format: "%.2f", settlement.amount)
            let note = "Split payment".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Split%20payment"
            lines.append("Venmo: venmo://paycharge?txn=pay&recipients=\(u)&amount=\(amt)&note=\(note)")
            lines.append("(Don't have Venmo? Search @\(u) in the app)")
        } else if let link = venmoPaymentLink { lines.append("Venmo: \(link)") }
        if let z = generateZelleDeepLink(amount: settlement.amount) { lines.append("Zelle: \(z)") }
        else if let note = zellePhoneNote { lines.append(note) }
        if !lines.isEmpty { text += "Quick Pay:\n"; lines.forEach { text += "\($0)\n" }; text += "\n" }
        text += "Via Dutch"
        return text
    }

    private func sendReminder(for settlement: SettlementSnapshot) {
        let phone = phoneNumber(for: settlement.fromName)
        let body = reminderMessage(for: settlement)
        HapticManager.impact(style: .medium)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        if MFMessageComposeViewController.canSendText() {
            let c = MFMessageComposeViewController()
            if let p = phone, !p.isEmpty { c.recipients = [p] }
            c.body = body
            c.messageComposeDelegate = MessageComposeCoordinator.shared
            func tryPresent() {
                var top = root
                while let p = top.presentedViewController {
                    if p.isBeingDismissed { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tryPresent() }; return }
                    top = p
                }
                top.present(c, animated: true)
            }
            tryPresent()
        } else {
            var sms = "sms:"
            if let p = phone, !p.isEmpty { sms += p }
            let enc = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            sms += "&body=\(enc)"
            if let url = URL(string: sms) { UIApplication.shared.open(url) }
        }
    }

    var body: some View {
        ZStack {
            ivory.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Split Details")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(ink)
                        Text("\(record.formattedDate) at \(record.formattedTime)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { HapticManager.impact(style: .light); dismiss() }) {
                        XMarkProfileIcon(size: 13, color: ink)
                            .frame(width: 36, height: 36)
                            .background(chalk)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink, lineWidth: 1.2))
                            .cornerRadius(8)
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Rectangle()
                    .fill(ink)
                    .frame(height: 1.5)
                    .padding(.horizontal, 20)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 18) {
                        summaryCard
                        transactionsSection
                        settlementsSection
                        Spacer(minLength: 40)
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Split Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summaryCard: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    if let groupName = record.groupName, !groupName.isEmpty {
                        Text(groupName.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(ink.opacity(0.55))
                            .tracking(1.4)
                    }
                    Text(record.yourBalance > 0 ? "You were owed" : record.yourBalance < 0 ? "You owed" : "All settled")
                        .font(.system(size: 14, weight: .medium)).foregroundColor(.secondary)
                    if record.yourBalance != 0 {
                        Text(record.formattedBalance).font(.system(size: 32, weight: .bold))
                            .foregroundColor(ink)
                    } else {
                        Text("$0.00").font(.system(size: 32, weight: .bold)).foregroundColor(ink)
                    }
                }
                Spacer()
            }
            HStack(spacing: 0) {
                statItem(value: record.formattedTotal, label: "Total")
                Divider().frame(height: 40)
                statItem(value: "\(record.participantCount)", label: "People")
                Divider().frame(height: 40)
                statItem(value: "\(record.transactionCount)", label: "Transactions")
            }
        }
        .padding(24)
        .background(chalk)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink, lineWidth: 1.5))
        .cornerRadius(8)
    }

    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transactions")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(ink)
                .padding(.horizontal, 4)

            if transactionSnapshots.isEmpty {
                Text("Transaction details were not saved for this older split.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(chalk)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink.opacity(0.18), lineWidth: 1))
                    .cornerRadius(8)
            } else {
                VStack(spacing: 10) {
                    ForEach(transactionSnapshots) { transactionRow($0) }
                }
            }
        }
    }

    private func transactionRow(_ transaction: TransactionSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(transaction.merchant.isEmpty ? "Transaction" : transaction.merchant)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(ink)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let assignment = transaction.assignmentLabel,
                       !assignment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(assignment)
                    } else {
                        Text("\(transaction.splitCount) split\(transaction.splitCount == 1 ? "" : "s")")
                    }
                    Text("·")
                    Text("\(transaction.splitCount) people")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            Text(String(format: "$%.2f", transaction.amount))
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(ink)
        }
        .padding(16)
        .background(chalk)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink.opacity(0.22), lineWidth: 1))
        .cornerRadius(8)
    }

    private var settlementsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settlements")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(ink)
                .padding(.horizontal, 4)
            if record.settlements.isEmpty {
                Text("No payment reminders for this split.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(chalk)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink.opacity(0.18), lineWidth: 1))
                    .cornerRadius(8)
            } else {
                VStack(spacing: 10) {
                    ForEach(record.settlements) { settlementRow($0) }
                }
            }
        }
    }

    private func settlementRow(_ settlement: SettlementSnapshot) -> some View {
        let hasReminded = remindedSettlements.contains(settlement.id)
        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(ivory).frame(width: 44, height: 44)
                ArrowRightSmallIcon(size: 16, color: ink)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(settlement.fromName).font(.system(size: 15, weight: .semibold)).foregroundColor(ink)
                    ArrowRightSmallIcon(size: 13, color: .secondary)
                    Text(settlement.toName).font(.system(size: 15, weight: .semibold)).foregroundColor(ink)
                }
                Text(settlement.formattedAmount).font(.system(size: 14, weight: .medium)).foregroundColor(.secondary)
            }
            Spacer()
            Button(action: {
                guard !hasReminded else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { remindedSettlements.insert(settlement.id) }
                sendReminder(for: settlement)
            }) {
                Text(hasReminded ? "Sent ✓" : "Remind")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(hasReminded ? ink : ivory)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(hasReminded ? ivory : ink))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink.opacity(hasReminded ? 0.18 : 0), lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle(scale: 0.93))
            .disabled(hasReminded)
        }
        .padding(16)
        .background(chalk)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink.opacity(0.22), lineWidth: 1))
        .cornerRadius(8)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Text(value).font(.system(size: 16, weight: .bold)).foregroundColor(ink)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
