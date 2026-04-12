import WidgetKit
import SwiftUI

@main
struct PeerDropWidgetBundle: WidgetBundle {
    var body: some Widget {
        PetWidget()
        if #available(iOSApplicationExtension 16.2, *) {
            PetLiveActivity()
        }
    }
}
