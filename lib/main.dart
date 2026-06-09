import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:archive/archive_io.dart';
import 'package:share_plus/share_plus.dart';

// ─────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────

late Directory _appDir;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  _appDir = await getApplicationDocumentsDirectory();
  await Hive.openBox('folders');
  await Hive.openBox('notes');
  await Hive.openBox('meta');
  runApp(const NoteChatApp());
}

// ─────────────────────────────────────────────────────────────
// Models (stored as Maps in Hive — simpler than custom adapters)
// ─────────────────────────────────────────────────────────────

class Folder {
  final String id;
  final String name;
  final IconData icon;
  final Color color;

  const Folder({required this.id, required this.name, required this.icon, required this.color});

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'iconCode': icon.codePoint,
    'iconFont': icon.fontFamily,
    'colorValue': color.value,
  };

  static Folder fromMap(Map m) => Folder(
    id: m['id'],
    name: m['name'],
    icon: IconData(m['iconCode'], fontFamily: m['iconFont'] ?? 'MaterialIcons'),
    color: Color(m['colorValue']),
  );
}

enum NoteType { text, image, file, voice }

class Note {
  final String id;
  final NoteType type;
  String text; // text body OR caption OR filename (mutable for editing)
  final String? filePath; // absolute path for image/file/voice
  final int? durationMs; // voice duration
  final DateTime createdAt;
  DateTime? editedAt; // null = never edited
  String? folderId;

  Note({
    required this.id,
    required this.type,
    required this.text,
    this.filePath,
    this.durationMs,
    required this.createdAt,
    this.editedAt,
    this.folderId,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'type': type.name,
    'text': text,
    'filePath': filePath,
    'durationMs': durationMs,
    'createdAt': createdAt.toIso8601String(),
    'editedAt': editedAt?.toIso8601String(),
    'folderId': folderId,
  };

  static Note fromMap(Map m) => Note(
    id: m['id'],
    type: NoteType.values.firstWhere((e) => e.name == m['type'], orElse: () => NoteType.text),
    text: m['text'] ?? '',
    filePath: m['filePath'],
    durationMs: m['durationMs'],
    createdAt: DateTime.parse(m['createdAt']),
    editedAt: m['editedAt'] != null ? DateTime.parse(m['editedAt']) : null,
    folderId: m['folderId'],
  );
}

// ─────────────────────────────────────────────────────────────
// Storage helpers
// ─────────────────────────────────────────────────────────────

class Repo {
  static final foldersBox = Hive.box('folders');
  static final notesBox = Hive.box('notes');
  static final metaBox = Hive.box('meta');

  static List<Folder> getFolders() {
    final raw = foldersBox.values.toList();
    // final hasBeenSeeded = metaBox.get('foldersSeeded', defaultValue: false) as bool;

    // Only seed defaults on the very first run, ever.
    // After that, an empty folder list means the user intentionally deleted everything.
    // if (raw.isEmpty && !hasBeenSeeded) {
    //   final defaults = [
    //     const Folder(id: 'work', name: 'Work', icon: Icons.work_outline, color: Color(0xFF7F77DD)),
    //     const Folder(id: 'ideas', name: 'Ideas', icon: Icons.lightbulb_outline, color: Color(0xFF1D9E75)),
    //     const Folder(id: 'shop', name: 'Shop', icon: Icons.shopping_cart_outlined, color: Color(0xFFD85A30)),
    //     const Folder(id: 'read', name: 'Read', icon: Icons.menu_book_outlined, color: Color(0xFFD4537E)),
    //   ];
    //   for (final f in defaults) {
    //     foldersBox.put(f.id, f.toMap());
    //   }
    //   metaBox.put('foldersSeeded', true);
    //   return defaults;
    // }

    return raw.map((m) => Folder.fromMap(Map<String, dynamic>.from(m))).toList();
  }
  static void saveFolder(Folder f) => foldersBox.put(f.id, f.toMap());
  static void deleteFolder(String id) => foldersBox.delete(id);

  static List<Note> getNotes() {
    return notesBox.values.map((m) => Note.fromMap(Map<String, dynamic>.from(m))).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  static void saveNote(Note n) => notesBox.put(n.id, n.toMap());
  static void deleteNote(String id) {
    final m = notesBox.get(id);
    if (m != null) {
      final note = Note.fromMap(Map<String, dynamic>.from(m));
      // Clean up attachment files
      if (note.filePath != null) {
        try {
          final f = File(note.filePath!);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
    notesBox.delete(id);
  }
}

// ─────────────────────────────────────────────────────────────
// Backup / Restore
// ─────────────────────────────────────────────────────────────

class BackupService {
  static const int _version = 1;

  /// Creates a .zip backup of all folders, notes, and attachment files.
  /// Returns the path of the created zip file.
  static Future<String> export() async {
    // Determine which subdir an attachment belongs in based on note type
    String _subdirFor(String typeName) {
      switch (typeName) {
        case 'image': return 'images';
        case 'file': return 'files';
        case 'voice': return 'voice';
        default: return 'misc';
      }
    }

    // Serialize folders
    final folders = Repo.getFolders().map((f) => f.toMap()).toList();

    // Serialize notes — convert absolute file paths to relative (subdir/filename)
    final notesRaw = Repo.getNotes();
    final notes = notesRaw.map((n) {
      final m = n.toMap();
      if (m['filePath'] != null) {
        final orig = m['filePath'] as String;
        final fname = orig.split(Platform.pathSeparator).last.split('/').last;
        final subdir = _subdirFor(m['type'] as String);
        m['filePath'] = '$subdir/$fname';
      }
      return m;
    }).toList();

    final payload = {
      'version': _version,
      'exportedAt': DateTime.now().toIso8601String(),
      'folders': folders,
      'notes': notes,
    };
    final jsonStr = jsonEncode(payload);

    // Build the zip
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final zipPath = '${_appDir.path}/notechat_backup_$ts.zip';
    // Make sure we don't clash with previous backups
    if (File(zipPath).existsSync()) File(zipPath).deleteSync();

    final encoder = ZipFileEncoder();
    encoder.create(zipPath);

    // Add manifest
    final jsonBytes = utf8.encode(jsonStr);
    encoder.addArchiveFile(ArchiveFile('backup.json', jsonBytes.length, jsonBytes));

    // Add attachment files
    for (final n in notesRaw) {
      if (n.filePath == null) continue;
      final f = File(n.filePath!);
      if (!f.existsSync()) continue;
      final subdir = _subdirFor(n.type.name);
      final fname = n.filePath!.split(Platform.pathSeparator).last.split('/').last;
      await encoder.addFile(f, '$subdir/$fname');
    }

    await encoder.close();
    return zipPath;
  }

  /// Restores a backup zip. Returns the number of notes restored.
  /// Notes/folders with the same id will be overwritten by the backup version.
  /// Existing notes/folders not in the backup are preserved.
  static Future<({int notes, int folders})> import(String zipPath) async {
    final bytes = File(zipPath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);

    // Find backup.json
    final jsonEntry = archive.files.firstWhere(
          (f) => f.name == 'backup.json',
      orElse: () => throw const FormatException('Not a valid NoteChat backup (missing backup.json)'),
    );
    final jsonStr = utf8.decode(jsonEntry.content as List<int>);
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;

    final version = data['version'] as int? ?? 1;
    if (version > _version) {
      throw FormatException('Backup is from a newer version of the app ($version). Update the app first.');
    }

    // Restore folders
    final folders = (data['folders'] as List).cast<Map>();
    for (final m in folders) {
      Repo.saveFolder(Folder.fromMap(Map<String, dynamic>.from(m)));
    }

    // Restore notes — extract attachments first, then save the note pointing to the new path
    final notes = (data['notes'] as List).cast<Map>();
    int restored = 0;
    for (final raw in notes) {
      final m = Map<String, dynamic>.from(raw);

      if (m['filePath'] != null) {
        final relPath = m['filePath'] as String; // e.g. "images/123_foo.jpg"
        final parts = relPath.split('/');
        if (parts.length == 2) {
          final subdir = parts[0];
          final fname = parts[1];

          // Find the archive entry
          ArchiveFile? entry;
          for (final f in archive.files) {
            if (f.name == relPath) { entry = f; break; }
          }
          if (entry != null) {
            final destDir = Directory('${_appDir.path}/$subdir');
            if (!destDir.existsSync()) destDir.createSync(recursive: true);
            // If a file with same name already exists, suffix to avoid collision
            String destName = fname;
            int n = 0;
            while (File('${destDir.path}/$destName').existsSync()) {
              n++;
              destName = '${n}_$fname';
            }
            final destPath = '${destDir.path}/$destName';
            File(destPath).writeAsBytesSync(entry.content as List<int>);
            m['filePath'] = destPath;
          } else {
            // Attachment missing from zip — null the path so bubble shows "broken" placeholder
            m['filePath'] = null;
          }
        }
      }

      Repo.saveNote(Note.fromMap(m));
      restored++;
    }

    return (notes: restored, folders: folders.length);
  }
}

// ─────────────────────────────────────────────────────────────
// App
// ─────────────────────────────────────────────────────────────

class NoteChatApp extends StatelessWidget {
  const NoteChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NoteChat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF7F7F8),
      ),
      home: const HomeScreen(),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Date filter
// ─────────────────────────────────────────────────────────────

enum DateFilter {
  all('All time'),
  today('Today'),
  week('This week'),
  month('This month');

  final String label;
  const DateFilter(this.label);

  bool matches(DateTime t) {
    final now = DateTime.now();
    switch (this) {
      case DateFilter.all:
        return true;
      case DateFilter.today:
        return t.year == now.year && t.month == now.month && t.day == now.day;
      case DateFilter.week:
        return now.difference(t).inDays < 7;
      case DateFilter.month:
        return t.year == now.year && t.month == now.month;
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Home screen
// ─────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const Folder _inboxFolder =
  Folder(id: 'inbox', name: 'All', icon: Icons.inbox_rounded, color: Color(0xFF6B7280));

  List<Folder> _folders = [];
  List<Note> _notes = [];
  String _selectedFolderId = 'inbox';
  DateFilter _dateFilter = DateFilter.all;
  String? _flashNoteId;

  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _folders = [_inboxFolder, ...Repo.getFolders()];
      _notes = Repo.getNotes();
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<Note> get _visibleNotes {
    return _notes.where((n) {
      if (_selectedFolderId != 'inbox' && n.folderId != _selectedFolderId) return false;
      if (!_dateFilter.matches(n.createdAt)) return false;
      return true;
    }).toList();
  }

  Folder? _folderById(String? id) {
    if (id == null) return null;
    return _folders.firstWhere((f) => f.id == id, orElse: () => _inboxFolder);
  }

  // ── Note actions ─────────────────────────────────────────

  void _sendTextNote() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    final note = Note(
      id: _newId(),
      type: NoteType.text,
      text: text,
      createdAt: DateTime.now(),
      folderId: _selectedFolderId == 'inbox' ? null : _selectedFolderId,
    );
    Repo.saveNote(note);
    _inputController.clear();
    _reload();
    _scrollToBottom();
  }

  Future<void> _attachImage({required ImageSource source}) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, imageQuality: 85);
    if (picked == null) return;
    final saved = await _copyToAppDir(picked.path, 'images');
    if (saved == null) return;
    Repo.saveNote(Note(
      id: _newId(),
      type: NoteType.image,
      text: '',
      filePath: saved,
      createdAt: DateTime.now(),
      folderId: _selectedFolderId == 'inbox' ? null : _selectedFolderId,
    ));
    _reload();
    _scrollToBottom();
  }

  Future<void> _attachFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.single.path == null) return;
    final picked = result.files.single;
    final saved = await _copyToAppDir(picked.path!, 'files');
    if (saved == null) return;
    Repo.saveNote(Note(
      id: _newId(),
      type: NoteType.file,
      text: picked.name,
      filePath: saved,
      createdAt: DateTime.now(),
      folderId: _selectedFolderId == 'inbox' ? null : _selectedFolderId,
    ));
    _reload();
    _scrollToBottom();
  }

  Future<String?> _copyToAppDir(String srcPath, String subDir) async {
    try {
      final dir = Directory('${_appDir.path}/$subDir');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final fileName = '${DateTime.now().millisecondsSinceEpoch}_${srcPath.split('/').last}';
      final dest = '${dir.path}/$fileName';
      await File(srcPath).copy(dest);
      return dest;
    } catch (e) {
      return null;
    }
  }

  Future<void> _saveVoiceNote(String path, int durationMs) async {
    Repo.saveNote(Note(
      id: _newId(),
      type: NoteType.voice,
      text: '',
      filePath: path,
      durationMs: durationMs,
      createdAt: DateTime.now(),
      folderId: _selectedFolderId == 'inbox' ? null : _selectedFolderId,
    ));
    _reload();
    _scrollToBottom();
  }

  void _assignNoteToFolder(String noteId, String folderId) {
    final m = Repo.notesBox.get(noteId);
    if (m == null) return;
    final note = Note.fromMap(Map<String, dynamic>.from(m));
    note.folderId = folderId == 'inbox' ? null : folderId;
    Repo.saveNote(note);
    _reload();
  }

  Future<void> _confirmDelete(Note note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete note?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      Repo.deleteNote(note.id);
      _reload();
    }
  }

  Future<void> _editNote(Note note) async {
    final newText = await showDialog<String>(
      context: context,
      builder: (_) => _EditNoteDialog(initial: note.text),
    );
    if (newText != null && newText.trim().isNotEmpty && newText.trim() != note.text) {
      note.text = newText.trim();
      note.editedAt = DateTime.now();
      Repo.saveNote(note);
      _reload();
    }
  }

  void _showNoteMenu(Note note) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (note.type == NoteType.text)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(context);
                  _editNote(note);
                },
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('Move to folder'),
              onTap: () {
                Navigator.pop(context);
                _showMovePicker(note);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(note);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showMovePicker(Note note) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: _folders.map((f) {
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: f.color.withOpacity(0.15),
                child: Icon(f.icon, color: f.color, size: 18),
              ),
              title: Text(f.name),
              onTap: () {
                _assignNoteToFolder(note.id, f.id);
                Navigator.pop(context);
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  // ── Folder actions ───────────────────────────────────────

  Future<void> _addFolder() async {
    final result = await showDialog<Folder>(
      context: context,
      builder: (_) => const _FolderEditorDialog(),
    );
    if (result != null) {
      Repo.saveFolder(result);
      _reload();
    }
  }

  Future<void> _editFolder(Folder folder) async {
    final result = await showDialog<Folder>(
      context: context,
      builder: (_) => _FolderEditorDialog(initial: folder),
    );
    if (result != null) {
      Repo.saveFolder(result);
      _reload();
    }
  }

  Future<void> _deleteFolder(Folder folder) async {
    // Count how many notes are in this folder so we can warn the user
    final affectedCount = _notes.where((n) => n.folderId == folder.id).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${folder.name}"?'),
        content: Text(
          affectedCount == 0
              ? 'This folder is empty. Delete it?'
              : '$affectedCount note${affectedCount == 1 ? "" : "s"} in this folder will be moved to All. The folder will be deleted.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      // Move notes in this folder back to inbox (null folderId)
      for (final n in _notes.where((n) => n.folderId == folder.id)) {
        n.folderId = null;
        Repo.saveNote(n);
      }
      Repo.deleteFolder(folder.id);
      if (_selectedFolderId == folder.id) _selectedFolderId = 'inbox';
      _reload();
    }
  }

  void _showFolderMenu(Folder folder) {
    // Don't allow editing the synthetic "All" folder
    if (folder.id == 'inbox') return;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: CircleAvatar(
                backgroundColor: folder.color.withOpacity(0.15),
                child: Icon(folder.icon, color: folder.color, size: 18),
              ),
              title: Text(folder.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              dense: true,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit folder'),
              onTap: () {
                Navigator.pop(context);
                _editFolder(folder);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete folder', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _deleteFolder(folder);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── Utility ──────────────────────────────────────────────

  String _newId() => '${DateTime.now().microsecondsSinceEpoch}';

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ── Backup / Restore ─────────────────────────────────────

  Future<void> _exportBackup() async {
    // Show non-dismissible progress while we zip
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final zipPath = await BackupService.export();
      if (mounted) Navigator.pop(context); // close progress
      // Share the zip via system share sheet
      await Share.shareXFiles(
        [XFile(zipPath)],
        text: 'NoteChat backup',
        subject: 'NoteChat backup',
      );
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  Future<void> _importBackup() async {
    // 1. Let the user pick a zip
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (picked == null || picked.files.single.path == null) return;
    final zipPath = picked.files.single.path!;

    // 2. Warn before merging
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Restore backup?'),
        content: const Text(
          'This will add the backup\'s notes and folders to your current data. '
              'Items with matching IDs will be overwritten by the backup. '
              'Your existing notes will not be deleted.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Restore')),
        ],
      ),
    );
    if (confirmed != true) return;

    // 3. Restore with progress
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final result = await BackupService.import(zipPath);
      if (mounted) Navigator.pop(context);
      _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Restored ${result.notes} notes and ${result.folders} folders'),
        ));
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restore failed: $e')));
      }
    }
  }

  void _showAttachMenu() {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo from gallery'),
              onTap: () {
                Navigator.pop(context);
                _attachImage(source: ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(context);
                _attachImage(source: ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('File (PDF, etc.)'),
              onTap: () {
                Navigator.pop(context);
                _attachFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSearch() async {
    final result = await Navigator.of(context).push<Note>(
      MaterialPageRoute(
        builder: (_) => SearchScreen(notes: _notes, folderResolver: _folderById),
      ),
    );
    if (result != null) {
      setState(() {
        _selectedFolderId = result.folderId ?? 'inbox';
        _dateFilter = DateFilter.all;
        _flashNoteId = result.id;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToNote(result.id));
    }
  }

  void _scrollToNote(String noteId) {
    final idx = _visibleNotes.indexWhere((n) => n.id == noteId);
    if (idx == -1 || !_scrollController.hasClients) return;
    final target = (idx * 80.0).clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(target, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _flashNoteId = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedFolder = _folders.firstWhere((f) => f.id == _selectedFolderId, orElse: () => _inboxFolder);
    final notes = _visibleNotes;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: selectedFolder.color.withOpacity(0.15),
              child: Icon(selectedFolder.icon, size: 16, color: selectedFolder.color),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(selectedFolder.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                Text('${notes.length} notes',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontWeight: FontWeight.normal)),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.search, color: Colors.black87), onPressed: _openSearch),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.black87),
            onSelected: (v) {
              switch (v) {
                case 'export': _exportBackup(); break;
                case 'import': _importBackup(); break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Row(children: [
                Icon(Icons.upload_outlined, size: 20), SizedBox(width: 10), Text('Export backup'),
              ])),
              PopupMenuItem(value: 'import', child: Row(children: [
                Icon(Icons.download_outlined, size: 20), SizedBox(width: 10), Text('Restore backup'),
              ])),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _DateFilterBar(
            current: _dateFilter,
            onChanged: (f) => setState(() => _dateFilter = f),
          ),
          Expanded(
            child: Row(
              children: [
                _FolderRail(
                  folders: _folders,
                  selectedFolderId: _selectedFolderId,
                  noteCountByFolderId: {
                    for (final f in _folders)
                      f.id: f.id == 'inbox'
                          ? _notes.length
                          : _notes.where((n) => n.folderId == f.id).length,
                  },
                  onSelect: (id) => setState(() => _selectedFolderId = id),
                  onAcceptNote: _assignNoteToFolder,
                  onAddFolder: _addFolder,
                  onLongPressFolder: _showFolderMenu,
                ),
                Expanded(
                  child: Column(
                    children: [
                      Expanded(
                        child: notes.isEmpty
                            ? _EmptyState(folderName: selectedFolder.name)
                            : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          itemCount: notes.length,
                          itemBuilder: (context, i) {
                            final note = notes[i];
                            return _NoteBubble(
                              note: note,
                              folder: _folderById(note.folderId),
                              flash: note.id == _flashNoteId,
                              onMenu: () => _showNoteMenu(note),
                            );
                          },
                        ),
                      ),
                      _InputBar(
                        controller: _inputController,
                        onSendText: _sendTextNote,
                        onAttach: _showAttachMenu,
                        onVoiceRecorded: _saveVoiceNote,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Date filter bar
// ─────────────────────────────────────────────────────────────

class _DateFilterBar extends StatelessWidget {
  final DateFilter current;
  final ValueChanged<DateFilter> onChanged;
  const _DateFilterBar({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: DateFilter.values.map((f) {
          final selected = f == current;
          final color = Theme.of(context).colorScheme.primary;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: ChoiceChip(
              label: Text(f.label, style: TextStyle(fontSize: 12, color: selected ? Colors.white : Colors.grey.shade700)),
              selected: selected,
              selectedColor: color,
              backgroundColor: Colors.grey.shade100,
              side: BorderSide.none,
              onSelected: (_) => onChanged(f),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Folder editor dialog (new folder)
// ─────────────────────────────────────────────────────────────

class _FolderEditorDialog extends StatefulWidget {
  final Folder? initial;
  const _FolderEditorDialog({this.initial});
  @override
  State<_FolderEditorDialog> createState() => _FolderEditorDialogState();
}

class _FolderEditorDialogState extends State<_FolderEditorDialog> {
  static const _colors = [
    // Red
    Color(0xFF7F1D1D), Color(0xFFEF4444), Color(0xFFFF6B6B), Color(0xFFFCA5A5),
    // Orange
    Color(0xFF78350F), Color(0xFFD85A30), Color(0xFFFF9F1C), Color(0xFFF59E0B), Color(0xFFFDBA74),
    // Yellow
    Color(0xFFA16207), Color(0xFFEAB308), Color(0xFFFFD93D), Color(0xFFFCD34D),
    // Green
    Color(0xFF064E3B), Color(0xFF10B981), Color(0xFF1D9E75), Color(0xFF6BCB77), Color(0xFF84CC16), Color(0xFFA7F3D0),
    // Cyan / Teal
    Color(0xFF134E4A), Color(0xFF14B8A6), Color(0xFF06B6D4), Color(0xFF99F6E4),
    // Blue
    Color(0xFF1E3A8A), Color(0xFF3B82F6), Color(0xFF0EA5E9), Color(0xFF4D96FF), Color(0xFF93C5FD),
    // Purple / Indigo
    Color(0xFF4A044E), Color(0xFF6366F1), Color(0xFF7F77DD), Color(0xFF8B5CF6), Color(0xFFC4B5FD),
    // Pink / Magenta
    Color(0xFFE94560), Color(0xFFF43F5E), Color(0xFFD4537E), Color(0xFFD946EF), Color(0xFFF9A8D4),
    // Neutrals
    Color(0xFF475569), Color(0xFF78716C),
  ];
  // static const _colors = [
  //   // Originals (20)
  //   Color(0xFF7F77DD), Color(0xFF1D9E75), Color(0xFFD85A30), Color(0xFFD4537E),
  //   Color(0xFF3B82F6), Color(0xFFEAB308), Color(0xFF14B8A6), Color(0xFF8B5CF6),
  //   Color(0xFFEF4444), Color(0xFF06B6D4), Color(0xFF84CC16), Color(0xFFF59E0B),
  //   Color(0xFF6366F1), Color(0xFFD946EF), Color(0xFFF43F5E), Color(0xFF10B981),
  //   Color(0xFF0EA5E9), Color(0xFF78716C), Color(0xFFA16207), Color(0xFF475569),
  //   // Pastels & soft tones
  //   Color(0xFFFCA5A5), Color(0xFFFCD34D), Color(0xFFA7F3D0), Color(0xFF93C5FD),
  //   Color(0xFFC4B5FD), Color(0xFFF9A8D4), Color(0xFFFDBA74), Color(0xFF99F6E4),
  //   // Deep / rich tones
  //   Color(0xFF7F1D1D), Color(0xFF1E3A8A), Color(0xFF064E3B), Color(0xFF4A044E),
  //   Color(0xFF78350F), Color(0xFF134E4A),
  //   // Vibrant accents
  //   Color(0xFFFF6B6B), Color(0xFFFF9F1C), Color(0xFFFFD93D), Color(0xFF6BCB77),
  //   Color(0xFF4D96FF), Color(0xFFE94560),
  // ];
  static const _icons = [
    // Work & productivity
    Icons.work_outline, Icons.business_center_outlined, Icons.computer_outlined, Icons.code,
    Icons.task_alt_outlined, Icons.checklist, Icons.event_note_outlined, Icons.schedule,
    // Ideas & creativity
    Icons.lightbulb_outline, Icons.psychology_outlined, Icons.auto_awesome_outlined, Icons.palette_outlined,
    Icons.brush_outlined, Icons.camera_alt_outlined, Icons.music_note_outlined, Icons.movie_outlined,
    // Personal & life
    Icons.favorite_outline, Icons.star_outline, Icons.flag_outlined, Icons.bookmark_outline,
    Icons.home_outlined, Icons.family_restroom, Icons.cake_outlined, Icons.celebration_outlined,
    // Shopping & money
    Icons.shopping_cart_outlined, Icons.shopping_bag_outlined, Icons.local_grocery_store_outlined, Icons.attach_money,
    Icons.savings_outlined, Icons.credit_card_outlined, Icons.receipt_long_outlined, Icons.calculate_outlined,
    // Health & fitness
    Icons.fitness_center, Icons.directions_run, Icons.self_improvement, Icons.spa_outlined,
    Icons.local_hospital_outlined, Icons.medical_services_outlined, Icons.healing_outlined, Icons.bedtime_outlined,
    // Food & drink
    Icons.restaurant, Icons.local_cafe_outlined, Icons.local_pizza_outlined, Icons.local_bar_outlined,
    // Travel & places
    Icons.flight, Icons.directions_car_outlined, Icons.train_outlined, Icons.map_outlined,
    Icons.beach_access_outlined, Icons.landscape_outlined,
    // Education & reading
    Icons.menu_book_outlined, Icons.school_outlined, Icons.translate, Icons.science_outlined,
    Icons.history_edu_outlined, Icons.calculate,
    // Communication
    Icons.email_outlined, Icons.phone_outlined, Icons.chat_outlined, Icons.group_outlined,
    // Tools & misc
    Icons.build_outlined, Icons.key_outlined, Icons.shield_outlined, Icons.pets_outlined,
    Icons.local_florist_outlined, Icons.eco_outlined, Icons.wb_sunny_outlined, Icons.nightlight_outlined,
    // Baby & family
    Icons.child_care, Icons.child_friendly_outlined, Icons.bedroom_baby_outlined, Icons.toys_outlined,
    Icons.stroller, Icons.crib,
    // Beauty & fashion
    Icons.face_retouching_natural, Icons.spa, Icons.diamond_outlined, Icons.checkroom,
    // Gifts (closest to "bow")
    Icons.card_giftcard, Icons.redeem,
    // Mood & misc
    Icons.cake, Icons.local_florist, Icons.emoji_emotions_outlined, Icons.mood_outlined,
  ];

  late final TextEditingController _name;
  late Color _color;
  late IconData _icon;

  bool get _isEdit => widget.initial != null;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial?.name ?? '');
    _color = widget.initial?.color ?? _colors.first;
    _icon = widget.initial?.icon ?? _icons.first;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Edit folder' : 'New folder'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Preview
            Center(
              child: CircleAvatar(
                radius: 28,
                backgroundColor: _color.withOpacity(0.15),
                child: Icon(_icon, color: _color, size: 26),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Folder name', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            Text('Color', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: _colors.map((c) {
                final selected = c == _color;
                return GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(
                      color: c, shape: BoxShape.circle,
                      border: Border.all(color: selected ? Colors.black : Colors.transparent, width: 2.5),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            Text('Icon', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(height: 6),
            // Cap the icon grid so a long list doesn't blow up dialog height
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 6, runSpacing: 6,
                  children: _icons.map((i) {
                    final selected = i == _icon;
                    return GestureDetector(
                      onTap: () => setState(() => _icon = i),
                      child: Container(
                        width: 36, height: 36,
                        decoration: BoxDecoration(
                          color: selected ? _color.withOpacity(0.2) : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: selected ? _color : Colors.transparent, width: 2),
                        ),
                        child: Icon(i, color: selected ? _color : Colors.grey.shade700, size: 18),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () {
            if (_name.text.trim().isEmpty) return;
            Navigator.pop(
              context,
              Folder(
                id: widget.initial?.id ?? 'f_${DateTime.now().microsecondsSinceEpoch}',
                name: _name.text.trim(),
                icon: _icon,
                color: _color,
              ),
            );
          },
          child: Text(_isEdit ? 'Save' : 'Create'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Edit note dialog (text notes)
// ─────────────────────────────────────────────────────────────

class _EditNoteDialog extends StatefulWidget {
  final String initial;
  const _EditNoteDialog({required this.initial});
  @override
  State<_EditNoteDialog> createState() => _EditNoteDialogState();
}

class _EditNoteDialogState extends State<_EditNoteDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    // Position cursor at end of text
    _controller.selection = TextSelection.collapsed(offset: widget.initial.length);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit note'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 3,
        maxLines: 10,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          hintText: 'Note text…',
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Search screen
// ─────────────────────────────────────────────────────────────

class SearchScreen extends StatefulWidget {
  final List<Note> notes;
  final Folder? Function(String?) folderResolver;
  const SearchScreen({super.key, required this.notes, required this.folderResolver});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  List<Note> get _results {
    if (_query.trim().isEmpty) return [];
    final q = _query.toLowerCase();
    final list = widget.notes.where((n) {
      // Search text body, captions, and file names
      return n.text.toLowerCase().contains(q);
    }).toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        leading: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.black87), onPressed: () => Navigator.pop(context)),
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          autofocus: true,
          decoration: InputDecoration(hintText: 'Search your notes…', hintStyle: TextStyle(color: Colors.grey.shade500), border: InputBorder.none),
          style: const TextStyle(fontSize: 16, color: Colors.black87),
          onChanged: (v) => setState(() => _query = v),
        ),
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              icon: Icon(Icons.close, color: Colors.grey.shade600),
              onPressed: () { _controller.clear(); setState(() => _query = ''); _focusNode.requestFocus(); },
            ),
        ],
      ),
      body: _query.trim().isEmpty
          ? _hint('Type to search across all folders', Icons.search)
          : results.isEmpty
          ? _hint('No notes match "$_query"', Icons.search_off)
          : ListView.separated(
        itemCount: results.length,
        separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey.shade100),
        itemBuilder: (context, i) {
          final note = results[i];
          final folder = widget.folderResolver(note.folderId);
          return _SearchResultTile(note: note, folder: folder, query: _query, onTap: () => Navigator.pop(context, note));
        },
      ),
    );
  }

  Widget _hint(String text, IconData icon) => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 48, color: Colors.grey.shade300),
      const SizedBox(height: 12),
      Text(text, style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
    ]),
  );
}

class _SearchResultTile extends StatelessWidget {
  final Note note;
  final Folder? folder;
  final String query;
  final VoidCallback onTap;
  const _SearchResultTile({required this.note, required this.folder, required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = folder?.color ?? Colors.grey.shade500;
    final displayText = note.type == NoteType.text ? note.text : (note.text.isEmpty ? _typeLabel(note.type) : note.text);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(color: color.withOpacity(0.15), shape: BoxShape.circle),
              child: Icon(folder?.icon ?? Icons.inbox_rounded, color: color, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _HighlightedText(
                    text: displayText,
                    query: query,
                    style: const TextStyle(fontSize: 14, color: Colors.black87),
                    highlightStyle: TextStyle(fontSize: 14, color: color, fontWeight: FontWeight.w700, backgroundColor: color.withOpacity(0.15)),
                  ),
                  const SizedBox(height: 4),
                  Row(children: [
                    Text(folder?.name ?? 'Inbox', style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500)),
                    Text(' · ', style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
                    Text(_formatTime(note.createdAt), style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _typeLabel(NoteType t) => switch (t) {
    NoteType.image => '📷 Photo',
    NoteType.file => '📎 File',
    NoteType.voice => '🎤 Voice message',
    NoteType.text => '',
  };

  String _formatTime(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class _HighlightedText extends StatelessWidget {
  final String text;
  final String query;
  final TextStyle style;
  final TextStyle highlightStyle;
  const _HighlightedText({required this.text, required this.query, required this.style, required this.highlightStyle});

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) return Text(text, style: style);
    final spans = <TextSpan>[];
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    int start = 0;
    while (start < text.length) {
      final idx = lowerText.indexOf(lowerQuery, start);
      if (idx < 0) { spans.add(TextSpan(text: text.substring(start), style: style)); break; }
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx), style: style));
      spans.add(TextSpan(text: text.substring(idx, idx + query.length), style: highlightStyle));
      start = idx + query.length;
    }
    return RichText(text: TextSpan(children: spans));
  }
}

// ─────────────────────────────────────────────────────────────
// Folder rail
// ─────────────────────────────────────────────────────────────

class _FolderRail extends StatelessWidget {
  final List<Folder> folders;
  final String selectedFolderId;
  final Map<String, int> noteCountByFolderId;
  final ValueChanged<String> onSelect;
  final void Function(String, String) onAcceptNote;
  final VoidCallback onAddFolder;
  final ValueChanged<Folder> onLongPressFolder;

  const _FolderRail({
    required this.folders, required this.selectedFolderId, required this.noteCountByFolderId,
    required this.onSelect, required this.onAcceptNote, required this.onAddFolder,
    required this.onLongPressFolder,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76, color: Colors.white,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: folders.length + 1,
        itemBuilder: (context, i) {
          if (i == folders.length) return _AddFolderButton(onTap: onAddFolder);
          final folder = folders[i];
          final isSelected = folder.id == selectedFolderId;
          final count = noteCountByFolderId[folder.id] ?? 0;
          return DragTarget<String>(
            onWillAcceptWithDetails: (_) => true,
            onAcceptWithDetails: (d) => onAcceptNote(d.data, folder.id),
            builder: (context, candidate, _) {
              final isHovering = candidate.isNotEmpty;
              return GestureDetector(
                onTap: () => onSelect(folder.id),
                onLongPress: () => onLongPressFolder(folder),
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                  child: Column(children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: isHovering ? 56 : 48, height: isHovering ? 56 : 48,
                      decoration: BoxDecoration(
                        color: folder.color.withOpacity(isHovering ? 0.25 : 0.12), shape: BoxShape.circle,
                        border: Border.all(
                          color: isHovering ? folder.color : (isSelected ? folder.color.withOpacity(0.6) : Colors.transparent),
                          width: isHovering ? 2.5 : 2,
                        ),
                        boxShadow: isHovering ? [BoxShadow(color: folder.color.withOpacity(0.3), blurRadius: 12, spreadRadius: 2)] : null,
                      ),
                      child: Icon(folder.icon, color: folder.color, size: 22),
                    ),
                    const SizedBox(height: 4),
                    Text(folder.name, style: TextStyle(fontSize: 10, color: isSelected ? folder.color : Colors.grey.shade700, fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400), overflow: TextOverflow.ellipsis),
                    if (count > 0) Text('$count', style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
                  ]),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _AddFolderButton extends StatelessWidget {
  final VoidCallback onTap;
  const _AddFolderButton({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        child: Column(children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.grey.shade400, width: 1.5)),
            child: Icon(Icons.add, color: Colors.grey.shade500, size: 22),
          ),
          const SizedBox(height: 4),
          Text('New', style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Note bubble — handles all 4 note types
// ─────────────────────────────────────────────────────────────

class _NoteBubble extends StatelessWidget {
  final Note note;
  final Folder? folder;
  final bool flash;
  final VoidCallback onMenu;
  const _NoteBubble({required this.note, this.folder, this.flash = false, required this.onMenu});

  @override
  Widget build(BuildContext context) {
    // Unfiled notes (no folder) → neutral gray. Filed notes → folder's color.
    final bubbleColor = folder?.color ?? const Color(0xFF6B7280);
    final bg = bubbleColor.withOpacity(flash ? 0.30 : 0.12);
    final fg = bubbleColor;

    Widget content;
    switch (note.type) {
      case NoteType.text:
        content = Text(note.text, style: TextStyle(fontSize: 14, color: fg.withOpacity(0.95)));
        break;
      case NoteType.image:
        content = ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: note.filePath != null && File(note.filePath!).existsSync()
              ? GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _ImageViewer(path: note.filePath!))),
            child: Image.file(File(note.filePath!), width: 200, fit: BoxFit.cover),
          )
              : Container(width: 200, height: 120, color: Colors.grey.shade200, child: const Icon(Icons.broken_image)),
        );
        break;
      case NoteType.file:
        content = GestureDetector(
          onTap: () { if (note.filePath != null) OpenFilex.open(note.filePath!); },
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.insert_drive_file_outlined, color: fg, size: 28),
            const SizedBox(width: 8),
            Flexible(child: Text(note.text, style: TextStyle(fontSize: 13, color: fg, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis, maxLines: 2)),
          ]),
        );
        break;
      case NoteType.voice:
        content = _VoicePlayer(path: note.filePath!, durationMs: note.durationMs ?? 0, color: fg);
        break;
    }

    final bubble = AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      margin: const EdgeInsets.only(bottom: 8),
      padding: note.type == NoteType.image ? const EdgeInsets.all(4) : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.65),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18), bottomLeft: Radius.circular(18), bottomRight: Radius.circular(4)),
        boxShadow: flash ? [BoxShadow(color: bubbleColor.withOpacity(0.4), blurRadius: 14, spreadRadius: 1)] : null,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        content,
        const SizedBox(height: 4),
        Padding(
          padding: note.type == NoteType.image ? const EdgeInsets.only(right: 6, bottom: 2) : EdgeInsets.zero,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (folder != null) ...[
              Icon(folder!.icon, size: 10, color: fg.withOpacity(0.6)),
              const SizedBox(width: 3),
              Text(folder!.name, style: TextStyle(fontSize: 9, color: fg.withOpacity(0.6))),
              const SizedBox(width: 6),
            ],
            Text(_formatTime(note.createdAt), style: TextStyle(fontSize: 9, color: fg.withOpacity(0.5))),
            if (note.editedAt != null) ...[
              const SizedBox(width: 4),
              Text('· edited', style: TextStyle(fontSize: 9, color: fg.withOpacity(0.5), fontStyle: FontStyle.italic)),
            ],
          ]),
        ),
      ]),
    );

    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onDoubleTap: onMenu,
        child: LongPressDraggable<String>(
          data: note.id,
          feedback: Material(color: Colors.transparent, child: Transform.rotate(angle: -0.03, child: bubble)),
          childWhenDragging: Opacity(opacity: 0.3, child: bubble),
          child: bubble,
        ),
      ),
    );
  }

  String _formatTime(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

// ─────────────────────────────────────────────────────────────
// Image viewer (full screen)
// ─────────────────────────────────────────────────────────────

class _ImageViewer extends StatelessWidget {
  final String path;
  const _ImageViewer({required this.path});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, elevation: 0),
      body: Center(child: InteractiveViewer(child: Image.file(File(path)))),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Voice player widget
// ─────────────────────────────────────────────────────────────

class _VoicePlayer extends StatefulWidget {
  final String path;
  final int durationMs;
  final Color color;
  const _VoicePlayer({required this.path, required this.durationMs, required this.color});
  @override
  State<_VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<_VoicePlayer> {
  final _player = AudioPlayer();
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  late Duration _duration;

  @override
  void initState() {
    super.initState();
    _duration = Duration(milliseconds: widget.durationMs);
    _player.onPositionChanged.listen((p) => mounted ? setState(() => _position = p) : null);
    _player.onPlayerComplete.listen((_) => mounted ? setState(() { _isPlaying = false; _position = Duration.zero; }) : null);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_isPlaying) {
      await _player.pause();
      setState(() => _isPlaying = false);
    } else {
      await _player.play(DeviceFileSource(widget.path));
      setState(() => _isPlaying = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _duration.inMilliseconds > 0 ? _position.inMilliseconds / _duration.inMilliseconds : 0.0;
    return SizedBox(
      width: 180,
      child: Row(children: [
        GestureDetector(
          onTap: _toggle,
          child: Container(
            width: 34, height: 34,
            decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
            child: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 20),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              backgroundColor: widget.color.withOpacity(0.2),
              valueColor: AlwaysStoppedAnimation(widget.color),
              minHeight: 3,
            ),
            const SizedBox(height: 4),
            Text(_format(_isPlaying ? _position : _duration), style: TextStyle(fontSize: 10, color: widget.color.withOpacity(0.7))),
          ]),
        ),
      ]),
    );
  }

  String _format(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ─────────────────────────────────────────────────────────────
// Input bar — text + attach + hold-to-record
// ─────────────────────────────────────────────────────────────

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSendText;
  final VoidCallback onAttach;
  final Future<void> Function(String path, int durationMs) onVoiceRecorded;
  const _InputBar({required this.controller, required this.onSendText, required this.onAttach, required this.onVoiceRecorded});

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  final _recorder = AudioRecorder();
  bool _isRecording = false;
  DateTime? _recordStart;
  Timer? _ticker;
  Duration _recordDuration = Duration.zero;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final has = widget.controller.text.trim().isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _recorder.dispose();
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _startRecording() async {
    final perm = await Permission.microphone.request();
    if (!perm.isGranted) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mic permission denied')));
      return;
    }
    if (!await _recorder.hasPermission()) return;
    final path = '${_appDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    setState(() {
      _isRecording = true;
      _recordStart = DateTime.now();
      _recordDuration = Duration.zero;
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_recordStart != null) setState(() => _recordDuration = DateTime.now().difference(_recordStart!));
    });
  }

  Future<void> _stopRecording({bool cancel = false}) async {
    _ticker?.cancel();
    final path = await _recorder.stop();
    final durMs = _recordDuration.inMilliseconds;
    setState(() => _isRecording = false);
    if (cancel || path == null || durMs < 500) {
      // too short → discard
      if (path != null) { try { File(path).deleteSync(); } catch (_) {} }
      return;
    }
    await widget.onVoiceRecorded(path, durMs);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      decoration: BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Colors.grey.shade200))),
      child: SafeArea(
        top: false,
        child: _isRecording ? _buildRecordingUI() : _buildNormalUI(context),
      ),
    );
  }

  Widget _buildNormalUI(BuildContext context) {
    return Row(children: [
      IconButton(icon: Icon(Icons.attach_file, color: Colors.grey.shade600), onPressed: widget.onAttach),
      Expanded(
        child: TextField(
          controller: widget.controller,
          minLines: 1, maxLines: 5,
          textInputAction: TextInputAction.newline,
          decoration: InputDecoration(
            hintText: 'Type a note…', filled: true, fillColor: Colors.grey.shade100,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
          ),
        ),
      ),
      const SizedBox(width: 8),
      _hasText
          ? Material(
        color: Theme.of(context).colorScheme.primary, shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: widget.onSendText,
          child: const Padding(padding: EdgeInsets.all(10), child: Icon(Icons.arrow_upward, color: Colors.white, size: 20)),
        ),
      )
          : Material(
        color: Theme.of(context).colorScheme.primary, shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: _startRecording,
          child: const Padding(padding: EdgeInsets.all(10), child: Icon(Icons.mic, color: Colors.white, size: 20)),
        ),
      ),
    ]);
  }

  Widget _buildRecordingUI() {
    final s = _recordDuration.inSeconds.toString().padLeft(2, '0');
    final m = _recordDuration.inMinutes.toString().padLeft(1, '0');
    return Row(children: [
      // Cancel (red trash)
      Material(
        color: Colors.red.shade50,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _stopRecording(cancel: true),
          child: const Padding(
            padding: EdgeInsets.all(10),
            child: Icon(Icons.delete_outline, color: Colors.red, size: 20),
          ),
        ),
      ),
      const SizedBox(width: 10),
      // Live timer + pulsing dot
      Expanded(
        child: Row(children: [
          _PulsingDot(),
          const SizedBox(width: 8),
          Text('$m:$s', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600, fontSize: 15)),
          const SizedBox(width: 10),
          Flexible(
            child: Text('Recording…', style: TextStyle(color: Colors.grey.shade600, fontSize: 12), overflow: TextOverflow.ellipsis),
          ),
        ]),
      ),
      // Send (green checkmark)
      Material(
        color: Colors.green,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _stopRecording(),
          child: const Padding(
            padding: EdgeInsets.all(10),
            child: Icon(Icons.send, color: Colors.white, size: 20),
          ),
        ),
      ),
    ]);
  }
}

// Pulsing red dot to indicate active recording
class _PulsingDot extends StatefulWidget {
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);
  }
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.3, end: 1).animate(_c),
      child: Container(
        width: 10, height: 10,
        decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Empty state
// ─────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final String folderName;
  const _EmptyState({required this.folderName});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.chat_bubble_outline, size: 40, color: Colors.grey.shade400),
        const SizedBox(height: 12),
        Text('No notes in $folderName yet', style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
        const SizedBox(height: 4),
        Text('Type below, attach a file, or tap mic to record', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
      ]),
    );
  }
}