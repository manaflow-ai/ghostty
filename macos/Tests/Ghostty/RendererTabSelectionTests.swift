import Testing
@testable import Ghostty

struct RendererTabSelectionTests {
    private final class ObservationToken {}
    private final class ObservationGroup {}

    @Test func standaloneWindowIsSelected() {
        #expect(RendererTabSelection.classify(
            hasTabGroup: false,
            selectedWindowMatches: nil,
            isKeyOrMain: false
        ) == .selected)
    }

    @Test func matchingGroupSelectionIsSelected() {
        #expect(RendererTabSelection.classify(
            hasTabGroup: true,
            selectedWindowMatches: true,
            isKeyOrMain: false
        ) == .selected)
    }

    @Test func differentGroupSelectionIsDeselected() {
        #expect(RendererTabSelection.classify(
            hasTabGroup: true,
            selectedWindowMatches: false,
            isKeyOrMain: false
        ) == .deselected)
    }

    @Test func missingGroupSelectionIsAmbiguous() {
        #expect(RendererTabSelection.classify(
            hasTabGroup: true,
            selectedWindowMatches: nil,
            isKeyOrMain: false
        ) == .ambiguous)
    }

    @Test func keyWindowOverridesTransientGroupSelection() {
        #expect(RendererTabSelection.classify(
            hasTabGroup: true,
            selectedWindowMatches: false,
            isKeyOrMain: true
        ) == .selected)
    }

    @Test func keyWindowRemainsVisibleWhileOcclusionStateLagsTabSelection() {
        #expect(RendererTabVisibility.isVisible(
            selection: .selected,
            occlusionVisible: false,
            isKeyOrMain: true
        ))
    }

    @Test func tabOverviewClassifiesEveryMemberAsOverview() {
        #expect(RendererTabSelection.classify(
            hasTabGroup: true,
            selectedWindowMatches: false,
            isKeyOrMain: false,
            isOverviewVisible: true
        ) == .overview)
    }

    @Test func tabOverviewKeepsRendererVisibleAndNonReclaimable() {
        #expect(RendererTabVisibility.isVisible(
            selection: .overview,
            occlusionVisible: false,
            isKeyOrMain: false
        ))
        #expect(!RendererTabVisibility.shouldReclaimSynchronously(
            selection: .overview
        ))
    }

    @Test func deselectedTabReclaimsRendererInCurrentVisibilityPass() {
        #expect(RendererTabVisibility.shouldReclaimSynchronously(
            selection: .deselected
        ))
        #expect(!RendererTabVisibility.shouldReclaimSynchronously(
            selection: .selected
        ))
        #expect(!RendererTabVisibility.shouldReclaimSynchronously(
            selection: .ambiguous
        ))
    }

    @Test func missingSurfaceDoesNotRetryRendererReclamation() {
        var releaseAttempts = 0

        let needsRetry = RendererReclamationRetry.shouldRetry(
            hasSurface: false,
            releaseAccepted: {
                releaseAttempts += 1
                return false
            }()
        )

        #expect(!needsRetry)
        #expect(releaseAttempts == 0)
    }

    @Test func tabGroupElectsOneRendererObservationOwner() {
        let controllers = (0..<100).map { _ in ObservationToken() }
        let observers = controllers.filter {
            RendererTabObservationPlan.shouldObserve(
                controller: $0,
                controllers: controllers
            )
        }

        #expect(observers.count == 1)
        #expect(observers.first === controllers.first)
    }

    @Test func tabGroupMembershipChangeElectsFirstSurvivor() {
        var controllers = (0..<3).map { _ in ObservationToken() }
        let originalOwner = controllers[0]
        let firstSurvivor = controllers[1]

        controllers.removeFirst()
        #expect(!RendererTabObservationPlan.shouldObserve(
            controller: originalOwner,
            controllers: controllers
        ))
        #expect(RendererTabObservationPlan.shouldObserve(
            controller: firstSurvivor,
            controllers: controllers
        ))
    }

    @Test func staleMembershipCallbackKeepsNewGroupObservation() {
        let originalOwner = ObservationToken()
        let oldGroupSurvivor = ObservationToken()
        let oldGroup = ObservationGroup()
        let newGroup = ObservationGroup()

        #expect(!RendererTabObservationPlan.shouldInvalidateCurrentObservation(
            observedGroup: newGroup,
            callbackGroup: oldGroup,
            controller: originalOwner,
            controllers: [oldGroupSurvivor]
        ))
    }

    @Test func currentMembershipCallbackHandsObservationToFirstSurvivor() {
        let originalOwner = ObservationToken()
        let oldGroupSurvivor = ObservationToken()
        let oldGroup = ObservationGroup()

        #expect(RendererTabObservationPlan.shouldInvalidateCurrentObservation(
            observedGroup: oldGroup,
            callbackGroup: oldGroup,
            controller: originalOwner,
            controllers: [oldGroupSurvivor]
        ))
    }
}
