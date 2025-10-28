import SwiftUI
import FloatplaneAPIClient

struct RootTabView: View {
	
	enum Selection: Hashable {
		case home
		case creator(String)
		case settings
	}
	
	@EnvironmentObject var userInfo: UserInfo
	@Environment(\.fpApiService) var fpApiService
	@Environment(\.managedObjectContext) var managedObjectContext
	@State var selection: Selection = .home
	
	var body: some View {
		TabView(selection: $selection) {
			HomeView(viewModel: HomeViewModel(userInfo: userInfo, fpApiService: fpApiService, managedObjectContext: managedObjectContext))
				.tag(Selection.home)
				.tabItem {
                    #if os(tvOS)
					Text("Home")
                    #else
                    Label("Home", systemImage: "house")
                    #endif
				}
			
			// There is an issue where multiple subscriptions for one creator might be active.
			// Instead of showing one tab per subscription, show one per creator.
			ForEach(userInfo.creatorsInOrder, id: \.0.id) { creator, creatorOwner in
				CreatorContentView(viewModel: CreatorContentViewModel(fpApiService: fpApiService,
																	  managedObjectContext: managedObjectContext,
																	  creatorOrChannel: creator,
																	  creatorOwner: creatorOwner,
																	  livestream: creator.liveStream))
					.tag(Selection.creator(creator.id))
					.tabItem {
                        #if os(tvOS)
                        Text(creator.title)
                        #else
                        Label(creator.title, systemImage: "person.crop.rectangle")
                        #endif
					}
			}
			SettingsView()
				.tag(Selection.settings)
				.tabItem {
                    #if os(tvOS)
                    Text("Settings")
                    #else
                    Label("Settings", systemImage: "gear")
                    #endif
				}
		}
	}
}

struct RootTabView_Previews: PreviewProvider {
	static var previews: some View {
		RootTabView()
			.environmentObject(MockData.userInfo)
			.environment(\.fpApiService, MockFPAPIService())
	}
}
