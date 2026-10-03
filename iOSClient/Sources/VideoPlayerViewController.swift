import AVFoundation
import AVKit
import UIKit

/// Full-screen progressive HTTP streaming (Google Photos style).
/// Server remuxes with fast-start so `moov` is near the front and byte-range
/// requests can begin playback without downloading the whole file.
final class VideoPlayerViewController: UIViewController {
    private let client: PhotoStreamAPIClient
    private let assetID: String
    private let placeholder: UIImage?

    private let playerController = AVPlayerViewController()
    private let closeButton = UIButton(type: .system)
    private let posterView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()
    private let errorLabel = UILabel()
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var stallObservation: NSKeyValueObservation?

    init(client: PhotoStreamAPIClient, assetID: String, placeholder: UIImage?) {
        self.client = client
        self.assetID = assetID
        self.placeholder = placeholder
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalPresentationCapturesStatusBarAppearance = true
    }

    required init?(coder: NSCoder) { nil }

    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        posterView.image = placeholder
        posterView.contentMode = .scaleAspectFit
        posterView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(posterView)

        playerController.showsPlaybackControls = true
        playerController.allowsPictureInPicturePlayback = false
        playerController.view.translatesAutoresizingMaskIntoConstraints = false
        playerController.view.backgroundColor = .black
        playerController.view.isHidden = true
        addChild(playerController)
        view.addSubview(playerController.view)
        playerController.didMove(toParent: self)

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)

        statusLabel.textColor = UIColor(white: 0.9, alpha: 1)
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.text = "Loading video…"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        errorLabel.textColor = UIColor(white: 0.85, alpha: 1)
        errorLabel.font = .systemFont(ofSize: 15, weight: .medium)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorLabel)

        closeButton.setImage(
            UIImage(
                systemName: "chevron.left",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            ),
            for: .normal
        )
        closeButton.tintColor = UIColor(white: 0.15, alpha: 1)
        closeButton.backgroundColor = UIColor(white: 0.94, alpha: 0.95)
        closeButton.layer.cornerRadius = 18
        closeButton.clipsToBounds = false
        closeButton.layer.shadowColor = UIColor.black.cgColor
        closeButton.layer.shadowOpacity = 0.18
        closeButton.layer.shadowOffset = CGSize(width: 0, height: 1)
        closeButton.layer.shadowRadius = 2
        closeButton.accessibilityLabel = "Back"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            posterView.topAnchor.constraint(equalTo: view.topAnchor),
            posterView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            posterView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            posterView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            playerController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -12),

            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),

            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),
        ])

        Task { await startPlayback() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player?.pause()
    }

    deinit {
        cleanup()
    }

    @objc private func closeTapped() {
        player?.pause()
        dismiss(animated: true)
    }

    private func cleanup() {
        statusObservation = nil
        stallObservation = nil
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        endObserver = nil
        player?.pause()
        player = nil
    }

    private func startPlayback() async {
        statusLabel.isHidden = false
        statusLabel.text = "Loading video…"
        let streamURL = await client.streamingVideoURL(assetID: assetID)
        let asset = AVURLAsset(url: streamURL, options: [
            AVURLAssetAllowsCellularAccessKey: true,
        ])
        let item = AVPlayerItem(asset: asset)
        // Buffer ahead a bit, but don't wait to fill a huge window before starting.
        item.preferredForwardBufferDuration = 8
        // Do NOT set preferredPeakBitRate — a cap below the file's bitrate stalls 4K HEVC.

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .none
        self.player = player
        playerController.player = player

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                self?.handleItemStatus(item.status, error: item.error)
            }
        }

        stallObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                switch player.timeControlStatus {
                case .waitingToPlayAtSpecifiedRate:
                    self.statusLabel.isHidden = false
                    self.statusLabel.text = "Buffering…"
                    self.spinner.startAnimating()
                case .playing:
                    self.statusLabel.isHidden = true
                    self.spinner.stopAnimating()
                case .paused:
                    break
                @unknown default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero) { finished in
                guard finished else { return }
                player?.play()
            }
        }
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status, error: Error?) {
        switch status {
        case .readyToPlay:
            spinner.stopAnimating()
            statusLabel.isHidden = true
            errorLabel.isHidden = true
            posterView.isHidden = true
            playerController.view.isHidden = false
            player?.play()
        case .failed:
            let ns = error as NSError?
            let detail: String
            if let ns {
                detail = "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
            } else {
                detail = "Could not play video"
            }
            showError(detail)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func showError(_ message: String) {
        spinner.stopAnimating()
        statusLabel.isHidden = true
        playerController.view.isHidden = true
        posterView.isHidden = false
        errorLabel.isHidden = false
        errorLabel.text = message
    }
}
