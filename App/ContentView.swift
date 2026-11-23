import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = Converter()
    @State private var picked: [PhotosPickerItem] = []
    @State private var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                if access != .authorized {
                    Section {
                        Text("Necesito acceso completo a Fotos para leer las originales y reemplazarlas.")
                        Button("Dar acceso") { Task { access = await PHPhotoLibrary.requestAuthorization(for: .readWrite) } }
                    }
                }
                Section {
                    Button { Task { await model.scan(all: false) } } label: {
                        Label("Buscar las recién recibidas", systemImage: "arrow.down.circle")
                    }
                    .disabled(model.running || access != .authorized)
                    Button { Task { await model.scan(all: true) } } label: {
                        Label("Buscar en toda la fototeca", systemImage: "magnifyingglass")
                    }
                    .disabled(model.running || access != .authorized)
                    PhotosPicker(selection: $picked, matching: .images, photoLibrary: .shared()) {
                        Label("Elegir fotos a mano", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(model.running || access != .authorized)
                    Button { importing = true } label: {
                        Label("Convertir archivos…", systemImage: "folder")
                    }
                    .disabled(model.running || access != .authorized)
                    Toggle("Borrar las originales al terminar", isOn: $model.replaceOriginals)
                } footer: {
                    Text("Las fotos que mandas por AirDrop desde el S24 llegan como foto fija con el video escondido. Al abrir la app se buscan solas las que llegaron al último, aunque sean de hace semanas, y se vuelven Live Photos con la misma fecha, ubicación y álbumes. En la Mac, AirDrop las deja en Descargas: usa \"Convertir archivos…\" o arrástralas aquí; las originales se van a la Papelera.")
                }
                if let progress = model.progress { Section { Label(progress, systemImage: "hourglass") } }
                if model.items.isEmpty && !model.running && model.progress == nil {
                    Section { Text("No hay Motion Photos pendientes.").foregroundStyle(.secondary) }
                }
                if !model.items.isEmpty {
                    Section("\(model.pending.count) por convertir de \(model.items.count)") {
                        ForEach(model.items) { item in
                            HStack {
                                Text(item.name).lineLimit(1)
                                Spacer()
                                status(item.state)
                            }
                        }
                    }
                }
                if let message = model.message { Section { Text(message).foregroundStyle(.orange) } }
            }
            .navigationTitle("Motion a Live")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Convertir") { Task { await model.convertAll(); picked = [] } }
                        .disabled(model.running || model.pending.isEmpty)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.heic, .jpeg], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await model.loadFiles(urls) } }
            }
            .dropDestination(for: URL.self) { urls, _ in
                Task { await model.loadFiles(urls) }
                return !model.running
            }
            .onChange(of: picked) { _, items in
                Task { await model.load(items.compactMap(\.itemIdentifier)) }
            }
        }
        .task {
            if access == .notDetermined { access = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            if access == .authorized { await model.scan(all: false) }
        }
    }

    @ViewBuilder private func status(_ state: Item.State) -> some View {
        switch state {
        case .checking, .converting: ProgressView()
        case .motion: Label("Motion Photo", systemImage: "livephoto").foregroundStyle(.blue)
        case .notMotion: Text("Sin video").foregroundStyle(.secondary)
        case .done: Label("Live Photo", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let why): Text(why).foregroundStyle(.red).lineLimit(2)
        }
    }
}
