use dioxus::prelude::*;

const VIEW_BOX: &str = "0 0 24 24";

/// All available icon shapes
///
/// See the enum variants for the shape names. These names are always the
/// CamelCase version of the original heroicon name. So for example,
/// "arrow-narrow-left" becomes `ArrowNarrowLeft`.
#[allow(dead_code)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Shape {
    AcademicCap,
    Activity,
    AdjustmentsHorizontal,
    AdjustmentsVertical,
    Airplay,
    AlertCircle,
    AlertOctagon,
    AlertTriangle,
    AlignCenter,
    AlignJustify,
    AlignLeft,
    AlignRight,
    Anchor,
    Aperture,
    ArchiveBoxArrowDown,
    ArchiveBoxXMark,
    ArchiveBox,
    Archive,
    ArrowDownCircle,
    ArrowDownLeft,
    ArrowDownOnSquareStack,
    ArrowDownOnSquare,
    ArrowDownRight,
    ArrowDownTray,
    ArrowDown,
    ArrowLeftCircle,
    ArrowLeftOnRectangle,
    ArrowLeft,
    ArrowLongDown,
    ArrowLongLeft,
    ArrowLongRight,
    ArrowLongUp,
    ArrowPathRoundedSquare,
    ArrowPath,
    ArrowRightCircle,
    ArrowRightOnRectangle,
    ArrowRight,
    ArrowSmallDown,
    ArrowSmallLeft,
    ArrowSmallRight,
    ArrowSmallUp,
    ArrowTopRightOnSquare,
    ArrowTrendingDown,
    ArrowTrendingUp,
    ArrowUpCircle,
    ArrowUpLeft,
    ArrowUpOnSquareStack,
    ArrowUpOnSquare,
    ArrowUpRight,
    ArrowUpTray,
    ArrowUp,
    ArrowUturnDown,
    ArrowUturnLeft,
    ArrowUturnRight,
    ArrowUturnUp,
    ArrowsPointingIn,
    ArrowsPointingOut,
    ArrowsRightLeft,
    ArrowsUpDown,
    AtSign,
    AtSymbol,
    Award,
    Backspace,
    Backward,
    Banknotes,
    BarChart2,
    BarChart,
    Bars2,
    Bars3BottomLeft,
    Bars3BottomRight,
    Bars3CenterLeft,
    Bars3,
    Bars4,
    BarsArrowDown,
    BarsArrowUp,
    Battery0,
    Battery100,
    Battery50,
    BatteryCharging,
    Battery,
    Beaker,
    BellAlert,
    BellOff,
    BellSlash,
    BellSnooze,
    Bell,
    Bluetooth,
    Bold,
    BoltSlash,
    Bolt,
    BookOpen,
    Book,
    BookmarkSlash,
    BookmarkSquare,
    Bookmark,
    Box,
    Briefcase,
    BugAnt,
    BuildingLibrary,
    BuildingOffice2,
    BuildingOffice,
    BuildingStorefront,
    Cake,
    Calculator,
    CalendarDays,
    Calendar,
    CameraOff,
    Camera,
    Cast,
    ChartBarSquare,
    ChartBar,
    ChartPie,
    ChatBubbleBottomCenterText,
    ChatBubbleBottomCenter,
    ChatBubbleLeftEllipsis,
    ChatBubbleLeftRight,
    ChatBubbleLeft,
    ChatBubbleOvalLeftEllipsis,
    ChatBubbleOvalLeft,
    ChatPlus,
    ChatSlash,
    CheckBadge,
    CheckCircle,
    CheckSquare,
    Check,
    ChevronDoubleDown,
    ChevronDoubleLeft,
    ChevronDoubleRight,
    ChevronDoubleUp,
    ChevronDown,
    ChevronLeft,
    ChevronRight,
    ChevronUpDown,
    ChevronUp,
    ChevronsDown,
    ChevronsLeft,
    ChevronsRight,
    ChevronsUp,
    Chrome,
    CircleStack,
    Circle,
    ClipboardDocumentCheck,
    ClipboardDocumentList,
    ClipboardDocument,
    Clipboard,
    Clock,
    CloudArrowDown,
    CloudArrowUp,
    CloudDrizzle,
    CloudLightning,
    CloudOff,
    CloudRain,
    CloudSnow,
    Cloud,
    CodeBracketSquare,
    CodeBracket,
    Code,
    Codepen,
    Codesandbox,
    Coffee,
    Cog6Tooth,
    Cog8Tooth,
    Cog,
    Columns,
    CommandLine,
    Command,
    Compass,
    ComputerDesktop,
    Copy,
    CornerDownLeft,
    CornerDownRight,
    CornerLeftDown,
    CornerLeftUp,
    CornerRightDown,
    CornerRightUp,
    CornerUpLeft,
    CornerUpRight,
    CpuChip,
    Cpu,
    CreditCard,
    Crop,
    Crosshair,
    CubeTransparent,
    Cube,
    CurrencyBangladeshi,
    CurrencyDollar,
    CurrencyEuro,
    CurrencyPound,
    CurrencyRupee,
    CurrencyYen,
    CursorArrowRays,
    CursorArrowRipple,
    Database,
    Delete,
    DevicePhoneMobile,
    DeviceTablet,
    Disc,
    DivideCircle,
    DivideSquare,
    Divide,
    DocumentArrowDown,
    DocumentArrowUp,
    DocumentChartBar,
    DocumentCheck,
    DocumentDuplicate,
    DocumentMagnifyingGlass,
    DocumentMinus,
    DocumentPlus,
    DocumentText,
    Document,
    DollarSign,
    DownloadCloud,
    Download,
    Dribbble,
    Droplet,
    Edit2,
    Edit3,
    Edit,
    EllipsisHorizontalCircle,
    EllipsisHorizontal,
    EllipsisVertical,
    EnvelopeOpen,
    Envelope,
    ExclamationCircle,
    ExclamationTriangle,
    ExternalLink,
    EyeDropper,
    EyeOff,
    EyeSlash,
    Eye,
    FaceFrown,
    FaceSmile,
    Facebook,
    FastForward,
    Feather,
    Figma,
    FileMinus,
    FilePlus,
    FileText,
    File,
    Film,
    Filter,
    FingerPrint,
    Fire,
    Flag,
    FolderArrowDown,
    FolderMinus,
    FolderOpen,
    FolderPlus,
    Folder,
    Forward,
    Framer,
    Frown,
    Funnel,
    Gif,
    GiftTop,
    Gift,
    GitBranch,
    GitCommit,
    GitMerge,
    GitPullRequest,
    Github,
    Gitlab,
    GlobeAlt,
    GlobeAmericas,
    GlobeAsiaAustralia,
    GlobeEuropeAfrica,
    Globe,
    Grid,
    HandRaised,
    HandThumbDown,
    HandThumbUp,
    HardDrive,
    Hash,
    Hashtag,
    Headphones,
    Heart,
    HelpCircle,
    Hexagon,
    HomeModern,
    Home,
    Identification,
    Image,
    InboxArrowDown,
    InboxStack,
    Inbox,
    Info,
    InformationCircle,
    Instagram,
    Italic,
    Key,
    Language,
    Layers,
    Layout,
    LifeBuoy,
    Lifebuoy,
    LightBulb,
    Link2,
    Link,
    Linkedin,
    ListBullet,
    List,
    Loader,
    LockClosed,
    LockOpen,
    Lock,
    LogIn,
    LogOut,
    MagnifyingGlassCircle,
    MagnifyingGlassMinus,
    MagnifyingGlassPlus,
    MagnifyingGlass,
    Mail,
    MapPin,
    Map,
    Maximize2,
    Maximize,
    Megaphone,
    Meh,
    Menu,
    MessageCircle,
    MessageSquare,
    MicOff,
    Mic,
    Microphone,
    Minimize2,
    Minimize,
    MinusCircle,
    MinusSmall,
    MinusSquare,
    Minus,
    Monitor,
    Moon,
    MoreHorizontal,
    MoreVertical,
    MousePointer,
    Move,
    Music,
    MusicalNote,
    Navigation2,
    Navigation,
    Newspaper,
    NoSymbol,
    Octagon,
    Package,
    PaintBrush,
    PaperAirplane,
    PaperClip,
    Paperclip,
    PauseCircle,
    Pause,
    PenTool,
    PencilSquare,
    Pencil,
    Percent,
    PhoneArrowDownLeft,
    PhoneArrowUpRight,
    PhoneCall,
    PhoneForwarded,
    PhoneIncoming,
    PhoneMissed,
    PhoneOff,
    PhoneOutgoing,
    PhoneXMark,
    Phone,
    Photo,
    PieChart,
    PlayCircle,
    PlayPause,
    Play,
    PlusCircle,
    PlusSmall,
    PlusSquare,
    Plus,
    Pocket,
    Power,
    PresentationChartBar,
    PresentationChartLine,
    Printer,
    PuzzlePiece,
    QrCode,
    QuestionMarkCircle,
    QueueList,
    Radio,
    ReceiptPercent,
    ReceiptRefund,
    RectangleGroup,
    RectangleStack,
    RefreshCcw,
    RefreshCw,
    Repeat,
    ReplayOne,
    Rewind,
    RocketLaunch,
    RotateCcw,
    RotateCw,
    Rss,
    Save,
    Scale,
    Scissors,
    Search,
    Send,
    ServerStack,
    Server,
    Settings,
    Share2,
    Share,
    ShieldCheck,
    ShieldExclamation,
    ShieldOff,
    Shield,
    ShoppingBag,
    ShoppingCart,
    Shuffle,
    Sidebar,
    SignalSlash,
    Signal,
    SkipBack,
    SkipForward,
    Slack,
    Slash,
    Sliders,
    Smartphone,
    Smile,
    Sparkles,
    SpeakerWave,
    SpeakerXMark,
    Speaker,
    Square2Stack,
    Square3Stack3d,
    Square,
    Squares2x2,
    SquaresPlus,
    Star,
    StopCircle,
    Stop,
    Sun,
    Sunrise,
    Sunset,
    Swatch,
    TableCells,
    Table,
    Tablet,
    Tag,
    Target,
    Terminal,
    Thermometer,
    ThumbsDown,
    ThumbsUp,
    Ticket,
    ToggleLeft,
    ToggleRight,
    Tool,
    Trash2,
    Trash,
    Trello,
    TrendingDown,
    TrendingUp,
    Triangle,
    Trophy,
    Truck,
    Tv,
    Twitch,
    Twitter,
    Type,
    Umbrella,
    Underline,
    Unlock,
    UploadCloud,
    Upload,
    UserBlock,
    UserBlocked,
    UserCheck,
    UserCircle,
    UserGroup,
    UserMinus,
    UserPlus,
    UserX,
    User,
    Users,
    Variable,
    VideoCameraSlash,
    VideoCamera,
    VideoOff,
    Video,
    ViewColumns,
    ViewfinderCircle,
    Voicemail,
    Volume1,
    Volume2,
    VolumeX,
    Volume,
    Wallet,
    Watch,
    WifiOff,
    Wifi,
    Wind,
    WindowShare,
    Window,
    WrenchScrewdriver,
    Wrench,
    XCircle,
    XMark,
    XOctagon,
    XSquare,
    X,
    Youtube,
    ZapOff,
    Zap,
    ZoomIn,
    ZoomOut,
}

impl crate::IconShape for Shape {
    fn view_box(&self) -> &str {
        VIEW_BOX
    }

    fn path(&self) -> LazyNodes {
        match self {
            Shape::AcademicCap => rsx! {
                path {
                    d: "M4.25933 10.1468C3.98688 12.2308 3.82139 14.3485 3.76853 16.4941C6.66451 17.7032 9.41893 19.1836 12 20.9037C14.5811 19.1836 17.3355 17.7032 20.2315 16.4941C20.1786 14.3485 20.0131 12.2308 19.7407 10.1468M4.25933 10.1468C3.38362 9.85242 2.49729 9.5812 1.60107 9.33382C4.84646 7.05899 8.32741 5.09732 12 3.49268C15.6727 5.09732 19.1536 7.059 22.399 9.33383C21.5028 9.58122 20.6164 9.85245 19.7407 10.1468M4.25933 10.1468C6.94656 11.05 9.5338 12.171 12.0001 13.4888C14.4663 12.171 17.0535 11.0501 19.7407 10.1468M6.75 15.0001C7.16421 15.0001 7.5 14.6643 7.5 14.2501C7.5 13.8359 7.16421 13.5001 6.75 13.5001C6.33579 13.5001 6 13.8359 6 14.2501C6 14.6643 6.33579 15.0001 6.75 15.0001ZM6.75 15.0001V11.3246C8.44147 10.2736 10.1936 9.31107 12 8.44342M4.99264 19.9928C6.16421 18.8212 6.75 17.2857 6.75 15.7501V14.2501",
                },
            },
            Shape::Activity => rsx! {
                path {
                    d: "",
                },
            },
            Shape::AdjustmentsHorizontal => rsx! {
                path {
                    d: "M10.5 6L20.25 6M10.5 6C10.5 6.82843 9.82843 7.5 9 7.5C8.17157 7.5 7.5 6.82843 7.5 6M10.5 6C10.5 5.17157 9.82843 4.5 9 4.5C8.17157 4.5 7.5 5.17157 7.5 6M3.75 6H7.5M10.5 18H20.25M10.5 18C10.5 18.8284 9.82843 19.5 9 19.5C8.17157 19.5 7.5 18.8284 7.5 18M10.5 18C10.5 17.1716 9.82843 16.5 9 16.5C8.17157 16.5 7.5 17.1716 7.5 18M3.75 18L7.5 18M16.5 12L20.25 12M16.5 12C16.5 12.8284 15.8284 13.5 15 13.5C14.1716 13.5 13.5 12.8284 13.5 12M16.5 12C16.5 11.1716 15.8284 10.5 15 10.5C14.1716 10.5 13.5 11.1716 13.5 12M3.75 12H13.5",
                },
            },
            Shape::AdjustmentsVertical => rsx! {
                path {
                    d: "M6 13.5L6 3.75M6 13.5C6.82843 13.5 7.5 14.1716 7.5 15C7.5 15.8284 6.82843 16.5 6 16.5M6 13.5C5.17157 13.5 4.5 14.1716 4.5 15C4.5 15.8284 5.17157 16.5 6 16.5M6 20.25L6 16.5M18 13.5V3.75M18 13.5C18.8284 13.5 19.5 14.1716 19.5 15C19.5 15.8284 18.8284 16.5 18 16.5M18 13.5C17.1716 13.5 16.5 14.1716 16.5 15C16.5 15.8284 17.1716 16.5 18 16.5M18 20.25L18 16.5M12 7.5V3.75M12 7.5C12.8284 7.5 13.5 8.17157 13.5 9C13.5 9.82843 12.8284 10.5 12 10.5M12 7.5C11.1716 7.5 10.5 8.17157 10.5 9C10.5 9.82843 11.1716 10.5 12 10.5M12 20.25V10.5",
                },
            },
            Shape::Airplay => rsx! {
                path {
                    d: "M5 17H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-1",
                },
            },
            Shape::AlertCircle => rsx! {
                path {
                    d: "",
                },
            },
            Shape::AlertOctagon => rsx! {
                path {
                    d: "",
                },
            },
            Shape::AlertTriangle => rsx! {
                path {
                    d: "M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z",
                },
            },
            Shape::AlignCenter => rsx! {
                path {
                    d: "",
                },
            },
            Shape::AlignJustify => rsx! {
                path {
                    d: "",
                },
            },
            Shape::AlignLeft => rsx! {
                path {
                    d: "",
                },
            },
            Shape::AlignRight => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Anchor => rsx! {
                path {
                    d: "M5 12H2a10 10 0 0 0 20 0h-3",
                },
            },
            Shape::Aperture => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ArchiveBoxArrowDown => rsx! {
                path {
                    d: "M20.25 7.5L19.6246 18.1321C19.5546 19.3214 18.5698 20.25 17.3785 20.25H6.62154C5.43022 20.25 4.44538 19.3214 4.37542 18.1321L3.75 7.5M12 10.5V17.25M12 17.25L9 14.25M12 17.25L15 14.25M3.375 7.5H20.625C21.2463 7.5 21.75 6.99632 21.75 6.375V4.875C21.75 4.25368 21.2463 3.75 20.625 3.75H3.375C2.75368 3.75 2.25 4.25368 2.25 4.875V6.375C2.25 6.99632 2.75368 7.5 3.375 7.5Z",
                },
            },
            Shape::ArchiveBoxXMark => rsx! {
                path {
                    d: "M20.25 7.5L19.6246 18.1321C19.5546 19.3214 18.5698 20.25 17.3785 20.25H6.62154C5.43022 20.25 4.44538 19.3214 4.37542 18.1321L3.75 7.5M9.75 11.625L12 13.875M12 13.875L14.25 16.125M12 13.875L14.25 11.625M12 13.875L9.75 16.125M3.375 7.5H20.625C21.2463 7.5 21.75 6.99632 21.75 6.375V4.875C21.75 4.25368 21.2463 3.75 20.625 3.75H3.375C2.75368 3.75 2.25 4.25368 2.25 4.875V6.375C2.25 6.99632 2.75368 7.5 3.375 7.5Z",
                },
            },
            Shape::ArchiveBox => rsx! {
                path {
                    d: "M20.25 7.5L19.6246 18.1321C19.5546 19.3214 18.5698 20.25 17.3785 20.25H6.62154C5.43022 20.25 4.44538 19.3214 4.37542 18.1321L3.75 7.5M9.99976 11.25H13.9998M3.375 7.5H20.625C21.2463 7.5 21.75 6.99632 21.75 6.375V4.875C21.75 4.25368 21.2463 3.75 20.625 3.75H3.375C2.75368 3.75 2.25 4.25368 2.25 4.875V6.375C2.25 6.99632 2.75368 7.5 3.375 7.5Z",
                },
            },
            Shape::Archive => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ArrowDownCircle => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ArrowDownLeft => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ArrowDownOnSquareStack => rsx! {
                path {
                    d: "M7.5 7.5H6.75C5.50736 7.5 4.5 8.50736 4.5 9.75V17.25C4.5 18.4926 5.50736 19.5 6.75 19.5H14.25C15.4926 19.5 16.5 18.4926 16.5 17.25V9.75C16.5 8.50736 15.4926 7.5 14.25 7.5H13.5M7.5 11.25L10.5 14.25M10.5 14.25L13.5 11.25M10.5 14.25L10.5 1.5M16.5 10.5H17.25C18.4926 10.5 19.5 11.5074 19.5 12.75V20.25C19.5 21.4926 18.4926 22.5 17.25 22.5H9.75C8.50736 22.5 7.5 21.4926 7.5 20.25V19.5",
                },
            },
            Shape::ArrowDownOnSquare => rsx! {
                path {
                    d: "M9 8.25H7.5C6.25736 8.25 5.25 9.25736 5.25 10.5V19.5C5.25 20.7426 6.25736 21.75 7.5 21.75H16.5C17.7426 21.75 18.75 20.7426 18.75 19.5V10.5C18.75 9.25736 17.7426 8.25 16.5 8.25H15M9 12L12 15M12 15L15 12M12 15L12 2.25",
                },
            },
            Shape::ArrowDownRight => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ArrowDownTray => rsx! {
                path {
                    d: "M3 16.5V18.75C3 19.9926 4.00736 21 5.25 21H18.75C19.9926 21 21 19.9926 21 18.75V16.5M16.5 12L12 16.5M12 16.5L7.5 12M12 16.5V3",
                },
            },
            Shape::ArrowDown => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ArrowLeftCircle => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ArrowLeftOnRectangle => rsx! {
                path {
                    d: "M15.75 9V5.25C15.75 4.00736 14.7426 3 13.5 3L7.5 3C6.25736 3 5.25 4.00736 5.25 5.25L5.25 18.75C5.25 19.9926 6.25736 21 7.5 21H13.5C14.7426 21 15.75 19.9926 15.75 18.75V15M12 9L9 12M9 12L12 15M9 12L21.75 12",
                },
            },
            Shape::ArrowLeft => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ArrowLongDown => rsx! {
                path {
                    d: "M15.75 17.25L12 21M12 21L8.25 17.25M12 21L12 3",
                },
            },
            Shape::ArrowLongLeft => rsx! {
                path {
                    d: "M6.75 15.75L3 12M3 12L6.75 8.25M3 12H21",
                },
            },
            Shape::ArrowLongRight => rsx! {
                path {
                    d: "M17.25 8.25L21 12M21 12L17.25 15.75M21 12H3",
                },
            },
            Shape::ArrowLongUp => rsx! {
                path {
                    d: "M8.25 6.75L12 3M12 3L15.75 6.75M12 3V21",
                },
            },
            Shape::ArrowPathRoundedSquare => rsx! {
                path {
                    d: "M19.5 12C19.5 10.7681 19.4536 9.54699 19.3624 8.3384C19.2128 6.35425 17.6458 4.78724 15.6616 4.63757C14.453 4.54641 13.2319 4.5 12 4.5C10.7681 4.5 9.54699 4.54641 8.3384 4.63757C6.35425 4.78724 4.78724 6.35425 4.63757 8.3384C4.62097 8.55852 4.60585 8.77906 4.59222 9M19.5 12L22.5 9M19.5 12L16.5 9M4.5 12C4.5 13.2319 4.54641 14.453 4.63757 15.6616C4.78724 17.6458 6.35425 19.2128 8.3384 19.3624C9.54699 19.4536 10.7681 19.5 12 19.5C13.2319 19.5 14.453 19.4536 15.6616 19.3624C17.6458 19.2128 19.2128 17.6458 19.3624 15.6616C19.379 15.4415 19.3941 15.2209 19.4078 15M4.5 12L7.5 15M4.5 12L1.5 15",
                },
            },
            Shape::ArrowPath => rsx! {
                path {
                    d: "M16.0228 9.34841H21.0154V9.34663M2.98413 19.6444V14.6517M2.98413 14.6517L7.97677 14.6517M2.98413 14.6517L6.16502 17.8347C7.15555 18.8271 8.41261 19.58 9.86436 19.969C14.2654 21.1483 18.7892 18.5364 19.9685 14.1353M4.03073 9.86484C5.21 5.46374 9.73377 2.85194 14.1349 4.03121C15.5866 4.4202 16.8437 5.17312 17.8342 6.1655L21.0154 9.34663M21.0154 4.3558V9.34663",
                },
            },
            Shape::ArrowRightCircle => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ArrowRightOnRectangle => rsx! {
                path {
                    d: "M15.75 9V5.25C15.75 4.00736 14.7426 3 13.5 3L7.5 3C6.25736 3 5.25 4.00736 5.25 5.25L5.25 18.75C5.25 19.9926 6.25736 21 7.5 21H13.5C14.7426 21 15.75 19.9926 15.75 18.75V15M18.75 15L21.75 12M21.75 12L18.75 9M21.75 12L9 12",
                },
            },
            Shape::ArrowRight => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ArrowSmallDown => rsx! {
                path {
                    d: "M12 4.5V19.5M12 19.5L18.75 12.75M12 19.5L5.25 12.75",
                },
            },
            Shape::ArrowSmallLeft => rsx! {
                path {
                    d: "M19.5 12L4.5 12M4.5 12L11.25 18.75M4.5 12L11.25 5.25",
                },
            },
            Shape::ArrowSmallRight => rsx! {
                path {
                    d: "M4.5 12L19.5 12M19.5 12L12.75 5.25M19.5 12L12.75 18.75",
                },
            },
            Shape::ArrowSmallUp => rsx! {
                path {
                    d: "M12 19.5L12 4.5M12 4.5L5.25 11.25M12 4.5L18.75 11.25",
                },
            },
            Shape::ArrowTopRightOnSquare => rsx! {
                path {
                    d: "M13.5 6H5.25C4.00736 6 3 7.00736 3 8.25V18.75C3 19.9926 4.00736 21 5.25 21H15.75C16.9926 21 18 19.9926 18 18.75V10.5M7.5 16.5L21 3M21 3L15.75 3M21 3V8.25",
                },
            },
            Shape::ArrowTrendingDown => rsx! {
                path {
                    d: "M2.25 6L9 12.75L13.2862 8.46383C15.3217 10.0166 16.8781 12.23 17.5919 14.8941L18.3684 17.7919M18.3684 17.7919L21.5504 12.2806M18.3684 17.7919L12.857 14.6099",
                },
            },
            Shape::ArrowTrendingUp => rsx! {
                path {
                    d: "M2.25 18.0004L9 11.2504L13.3064 15.5568C14.5101 13.1885 16.5042 11.2027 19.1203 10.038L21.8609 8.81775M21.8609 8.81775L15.9196 6.53711M21.8609 8.81775L19.5802 14.759",
                },
            },
            Shape::ArrowUpCircle => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ArrowUpLeft => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ArrowUpOnSquareStack => rsx! {
                path {
                    d: "M7.5 7.5H6.75C5.50736 7.5 4.5 8.50736 4.5 9.75V17.25C4.5 18.4926 5.50736 19.5 6.75 19.5H14.25C15.4926 19.5 16.5 18.4926 16.5 17.25V9.75C16.5 8.50736 15.4926 7.5 14.25 7.5H13.5M13.5 4.5L10.5 1.5M10.5 1.5L7.5 4.5M10.5 1.5L10.5 12.75M16.5 10.5H17.25C18.4926 10.5 19.5 11.5074 19.5 12.75V20.25C19.5 21.4926 18.4926 22.5 17.25 22.5H9.75C8.50736 22.5 7.5 21.4926 7.5 20.25V19.5",
                },
            },
            Shape::ArrowUpOnSquare => rsx! {
                path {
                    d: "M9 8.25H7.5C6.25736 8.25 5.25 9.25736 5.25 10.5V19.5C5.25 20.7426 6.25736 21.75 7.5 21.75H16.5C17.7426 21.75 18.75 20.7426 18.75 19.5V10.5C18.75 9.25736 17.7426 8.25 16.5 8.25H15M15 5.25L12 2.25M12 2.25L9 5.25M12 2.25L12 15",
                },
            },
            Shape::ArrowUpRight => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ArrowUpTray => rsx! {
                path {
                    d: "M3 16.5V18.75C3 19.9926 4.00736 21 5.25 21H18.75C19.9926 21 21 19.9926 21 18.75V16.5M7.5 7.5L12 3M12 3L16.5 7.5M12 3L12 16.5",
                },
            },
            Shape::ArrowUp => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ArrowUturnDown => rsx! {
                path {
                    d: "M15 15L9 21M9 21L3 15M9 21V9C9 5.68629 11.6863 3 15 3C18.3137 3 21 5.68629 21 9V12",
                },
            },
            Shape::ArrowUturnLeft => rsx! {
                path {
                    d: "M9 15L3 9M3 9L9 3M3 9H15C18.3137 9 21 11.6863 21 15C21 18.3137 18.3137 21 15 21H12",
                },
            },
            Shape::ArrowUturnRight => rsx! {
                path {
                    d: "M15 15L21 9M21 9L15 3M21 9H9C5.68629 9 3 11.6863 3 15C3 18.3137 5.68629 21 9 21H12",
                },
            },
            Shape::ArrowUturnUp => rsx! {
                path {
                    d: "M9 9L15 3M15 3L21 9M15 3L15 15C15 18.3137 12.3137 21 9 21C5.68629 21 3 18.3137 3 15L3 12",
                },
            },
            Shape::ArrowsPointingIn => rsx! {
                path {
                    d: "M9 9L9 4.5M9 9L4.5 9M9 9L3.75 3.75M9 15L9 19.5M9 15L4.5 15M9 15L3.75 20.25M15 9H19.5M15 9V4.5M15 9L20.25 3.75M15 15H19.5M15 15L15 19.5M15 15L20.25 20.25",
                },
            },
            Shape::ArrowsPointingOut => rsx! {
                path {
                    d: "M3.75 3.75V8.25M3.75 3.75H8.25M3.75 3.75L9 9M3.75 20.25V15.75M3.75 20.25H8.25M3.75 20.25L9 15M20.25 3.75L15.75 3.75M20.25 3.75V8.25M20.25 3.75L15 9M20.25 20.25H15.75M20.25 20.25V15.75M20.25 20.25L15 15",
                },
            },
            Shape::ArrowsRightLeft => rsx! {
                path {
                    d: "M7.5 21L3 16.5M3 16.5L7.5 12M3 16.5H16.5M16.5 3L21 7.5M21 7.5L16.5 12M21 7.5L7.5 7.5",
                },
            },
            Shape::ArrowsUpDown => rsx! {
                path {
                    d: "M3 7.5L7.5 3M7.5 3L12 7.5M7.5 3V16.5M21 16.5L16.5 21M16.5 21L12 16.5M16.5 21L16.5 7.5",
                },
            },
            Shape::AtSign => rsx! {
                path {
                    d: "M16 8v5a3 3 0 0 0 6 0v-1a10 10 0 1 0-3.92 7.94",
                },
            },
            Shape::AtSymbol => rsx! {
                path {
                    d: "M16.5 12C16.5 14.4853 14.4853 16.5 12 16.5C9.51472 16.5 7.5 14.4853 7.5 12C7.5 9.51472 9.51472 7.5 12 7.5C14.4853 7.5 16.5 9.51472 16.5 12ZM16.5 12C16.5 13.6569 17.5074 15 18.75 15C19.9926 15 21 13.6569 21 12C21 9.69671 20.1213 7.3934 18.364 5.63604C14.8492 2.12132 9.15076 2.12132 5.63604 5.63604C2.12132 9.15076 2.12132 14.8492 5.63604 18.364C9.15076 21.8787 14.8492 21.8787 18.364 18.364M16.5 12V8.25",
                },
            },
            Shape::Award => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Backspace => rsx! {
                path {
                    d: "M12 9.75L14.25 12M14.25 12L16.5 14.25M14.25 12L16.5 9.75M14.25 12L12 14.25M9.42049 19.1705L3.04549 12.7955C2.60615 12.3562 2.60615 11.6438 3.04549 11.2045L9.42049 4.82951C9.63147 4.61853 9.91762 4.5 10.216 4.5L19.5 4.5C20.7426 4.5 21.75 5.50736 21.75 6.75V17.25C21.75 18.4926 20.7426 19.5 19.5 19.5H10.216C9.91762 19.5 9.63147 19.3815 9.42049 19.1705Z",
                },
            },
            Shape::Backward => rsx! {
                path {
                    d: "M21 16.811C21 17.6748 20.0668 18.2164 19.3168 17.7878L12.2094 13.7264C11.4536 13.2945 11.4536 12.2047 12.2094 11.7728L19.3168 7.71141C20.0668 7.28285 21 7.82439 21 8.68819V16.811Z M11.25 16.811C11.25 17.6748 10.3168 18.2164 9.56684 17.7878L2.45935 13.7264C1.70356 13.2945 1.70356 12.2047 2.45935 11.7728L9.56684 7.71141C10.3168 7.28285 11.25 7.82439 11.25 8.68819L11.25 16.811Z",
                },
            },
            Shape::Banknotes => rsx! {
                path {
                    d: "M2.25 18.75C7.71719 18.75 13.0136 19.4812 18.0468 20.8512C18.7738 21.0491 19.5 20.5086 19.5 19.7551V18.75M3.75 4.5V5.25C3.75 5.66421 3.41421 6 3 6H2.25M2.25 6V5.625C2.25 5.00368 2.75368 4.5 3.375 4.5H20.25M2.25 6V15M20.25 4.5V5.25C20.25 5.66421 20.5858 6 21 6H21.75M20.25 4.5H20.625C21.2463 4.5 21.75 5.00368 21.75 5.625V15.375C21.75 15.9963 21.2463 16.5 20.625 16.5H20.25M21.75 15H21C20.5858 15 20.25 15.3358 20.25 15.75V16.5M20.25 16.5H3.75M3.75 16.5H3.375C2.75368 16.5 2.25 15.9963 2.25 15.375V15M3.75 16.5V15.75C3.75 15.3358 3.41421 15 3 15H2.25M15 10.5C15 12.1569 13.6569 13.5 12 13.5C10.3431 13.5 9 12.1569 9 10.5C9 8.84315 10.3431 7.5 12 7.5C13.6569 7.5 15 8.84315 15 10.5ZM18 10.5H18.0075V10.5075H18V10.5ZM6 10.5H6.0075V10.5075H6V10.5Z",
                },
            },
            Shape::BarChart2 => rsx! {
                path {
                    d: "",
                },
            },
            Shape::BarChart => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Bars2 => rsx! {
                path {
                    d: "M3.75 9H20.25M3.75 15.75H20.25",
                },
            },
            Shape::Bars3BottomLeft => rsx! {
                path {
                    d: "M3.75 6.75H20.25M3.75 12H20.25M3.75 17.25H12",
                },
            },
            Shape::Bars3BottomRight => rsx! {
                path {
                    d: "M3.75 6.75H20.25M3.75 12H20.25M12 17.25H20.25",
                },
            },
            Shape::Bars3CenterLeft => rsx! {
                path {
                    d: "M3.75 6.75H20.25M3.75 12H12M3.75 17.25H20.25",
                },
            },
            Shape::Bars3 => rsx! {
                path {
                    d: "M3.75 6.75H20.25M3.75 12H20.25M3.75 17.25H20.25",
                },
            },
            Shape::Bars4 => rsx! {
                path {
                    d: "M3.75 5.25H20.25M3.75 9.75H20.25M3.75 14.25H20.25M3.75 18.75H20.25",
                },
            },
            Shape::BarsArrowDown => rsx! {
                path {
                    d: "M3 4.5H17.25M3 9H12.75M3 13.5H12.75M17.25 9V21M17.25 21L13.5 17.25M17.25 21L21 17.25",
                },
            },
            Shape::BarsArrowUp => rsx! {
                path {
                    d: "M3 4.5H17.25M3 9H12.75M3 13.5H8.25M13.5 12.75L17.25 9M17.25 9L21 12.75M17.25 9V21",
                },
            },
            Shape::Battery0 => rsx! {
                path {
                    d: "M21 10.5H21.375C21.9963 10.5 22.5 11.0037 22.5 11.625V13.875C22.5 14.4963 21.9963 15 21.375 15H21M3.75 18H18.75C19.9926 18 21 16.9926 21 15.75V9.75C21 8.50736 19.9926 7.5 18.75 7.5H3.75C2.50736 7.5 1.5 8.50736 1.5 9.75V15.75C1.5 16.9926 2.50736 18 3.75 18Z",
                },
            },
            Shape::Battery100 => rsx! {
                path {
                    d: "M21 10.5H21.375C21.9963 10.5 22.5 11.0037 22.5 11.625V13.875C22.5 14.4963 21.9963 15 21.375 15H21M4.5 10.5H18V15H4.5V10.5ZM3.75 18H18.75C19.9926 18 21 16.9926 21 15.75V9.75C21 8.50736 19.9926 7.5 18.75 7.5H3.75C2.50736 7.5 1.5 8.50736 1.5 9.75V15.75C1.5 16.9926 2.50736 18 3.75 18Z",
                },
            },
            Shape::Battery50 => rsx! {
                path {
                    d: "M21 10.5H21.375C21.9963 10.5 22.5 11.0037 22.5 11.625V13.875C22.5 14.4963 21.9963 15 21.375 15H21M4.5 10.5H11.25V15H4.5V10.5ZM3.75 18H18.75C19.9926 18 21 16.9926 21 15.75V9.75C21 8.50736 19.9926 7.5 18.75 7.5H3.75C2.50736 7.5 1.5 8.50736 1.5 9.75V15.75C1.5 16.9926 2.50736 18 3.75 18Z",
                },
            },
            Shape::BatteryCharging => rsx! {
                path {
                    d: "M5 18H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h3.19M15 6h2a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-3.19",
                },
            },
            Shape::Battery => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Beaker => rsx! {
                path {
                    d: "M9.75001 3.10408V8.81802C9.75001 9.41476 9.51295 9.98705 9.091 10.409L5.00001 14.5M9.75001 3.10408C9.49886 3.12743 9.24884 3.15465 9.00001 3.18568M9.75001 3.10408C10.4908 3.03521 11.2413 3 12 3C12.7587 3 13.5093 3.03521 14.25 3.10408M14.25 3.10408V8.81802C14.25 9.41476 14.4871 9.98705 14.909 10.409L19.8 15.3M14.25 3.10408C14.5011 3.12743 14.7512 3.15465 15 3.18568M19.8 15.3L18.2299 15.6925C16.1457 16.2136 13.9216 15.9608 12 15C10.0784 14.0392 7.85435 13.7864 5.7701 14.3075L5.00001 14.5M19.8 15.3L21.2022 16.7022C22.4341 17.9341 21.8527 20.0202 20.1354 20.3134C17.4911 20.7649 14.773 21 12 21C9.227 21 6.50891 20.7649 3.86459 20.3134C2.14728 20.0202 1.56591 17.9341 2.7978 16.7022L5.00001 14.5",
                },
            },
            Shape::BellAlert => rsx! {
                path {
                    d: "M14.8569 17.0817C16.7514 16.857 18.5783 16.4116 20.3111 15.7719C18.8743 14.177 17.9998 12.0656 17.9998 9.75V9.04919C17.9999 9.03281 18 9.01641 18 9C18 5.68629 15.3137 3 12 3C8.6863 3 6.00001 5.68629 6.00001 9L5.99982 9.75C5.99982 12.0656 5.12529 14.177 3.68849 15.7719C5.42142 16.4116 7.24845 16.857 9.14315 17.0818M14.8569 17.0817C13.92 17.1928 12.9666 17.25 11.9998 17.25C11.0332 17.25 10.0799 17.1929 9.14315 17.0818M14.8569 17.0817C14.9498 17.3711 15 17.6797 15 18C15 19.6569 13.6569 21 12 21C10.3432 21 9.00001 19.6569 9.00001 18C9.00001 17.6797 9.0502 17.3712 9.14315 17.0818M3.12445 7.5C3.41173 5.78764 4.18254 4.23924 5.29169 3M18.7083 3C19.8175 4.23924 20.5883 5.78764 20.8756 7.5",
                },
            },
            Shape::BellOff => rsx! {
                path {
                    d: "M13.73 21a2 2 0 0 1-3.46 0 M18.63 13A17.89 17.89 0 0 1 18 8 M6.26 6.26A5.86 5.86 0 0 0 6 8c0 7-3 9-3 9h14 M18 8a6 6 0 0 0-9.33-5",
                },
            },
            Shape::BellSlash => rsx! {
                path {
                    d: "M9.14314 17.0818C10.0799 17.1929 11.0332 17.25 11.9998 17.25C12.3306 17.25 12.6599 17.2433 12.9874 17.2301M9.14314 17.0818C7.24843 16.857 5.4214 16.4116 3.68848 15.7719C5.02539 14.2879 5.87549 12.3567 5.98723 10.2299M9.14314 17.0818C9.05019 17.3712 9 17.6797 9 18C9 19.6569 10.3431 21 12 21C13.2864 21 14.3837 20.1903 14.8101 19.0527M16.7749 16.7749L21 21M16.7749 16.7749C17.9894 16.5298 19.1706 16.1929 20.3111 15.7719C18.8743 14.177 17.9998 12.0656 17.9998 9.75V9.04919L18 9C18 5.68629 15.3137 3 12 3C9.5667 3 7.47171 4.44849 6.53026 6.53026M16.7749 16.7749L6.53026 6.53026M3 3L6.53026 6.53026",
                },
            },
            Shape::BellSnooze => rsx! {
                path {
                    d: "M14.8569 17.0817C16.7514 16.857 18.5783 16.4116 20.3111 15.7719C18.8743 14.177 17.9998 12.0656 17.9998 9.75V9.04919C17.9999 9.03281 18 9.01641 18 9C18 5.68629 15.3137 3 12 3C8.68629 3 6 5.68629 6 9L5.9998 9.75C5.9998 12.0656 5.12527 14.177 3.68848 15.7719C5.4214 16.4116 7.24843 16.857 9.14314 17.0818M14.8569 17.0817C13.92 17.1928 12.9666 17.25 11.9998 17.25C11.0332 17.25 10.0799 17.1929 9.14314 17.0818M14.8569 17.0817C14.9498 17.3711 15 17.6797 15 18C15 19.6569 13.6569 21 12 21C10.3431 21 9 19.6569 9 18C9 17.6797 9.05019 17.3712 9.14314 17.0818M10.5 8.25H13.5L10.5 12.75H13.5",
                },
            },
            Shape::Bell => rsx! {
                path {
                    d: "M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9 M13.73 21a2 2 0 0 1-3.46 0",
                },
            },
            Shape::Bluetooth => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Bold => rsx! {
                path {
                    d: "M6 4h8a4 4 0 0 1 4 4 4 4 0 0 1-4 4H6z M6 12h9a4 4 0 0 1 4 4 4 4 0 0 1-4 4H6z",
                },
            },
            Shape::BoltSlash => rsx! {
                path {
                    d: "M11.4123 15.6549L9.75 21.75L13.4949 17.7376M9.25736 13.5H3.75L6.40873 10.6514M8.4569 8.4569L14.25 2.25L12 10.5H20.25L15.5431 15.5431M8.4569 8.4569L3 3M8.4569 8.4569L15.5431 15.5431M15.5431 15.5431L21 21",
                },
            },
            Shape::Bolt => rsx! {
                path {
                    d: "M3.75 13.5L14.25 2.25L12 10.5H20.25L9.75 21.75L12 13.5H3.75Z",
                },
            },
            Shape::BookOpen => rsx! {
                path {
                    d: "M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z",
                },
            },
            Shape::Book => rsx! {
                path {
                    d: "M4 19.5A2.5 2.5 0 0 1 6.5 17H20 M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z",
                },
            },
            Shape::BookmarkSlash => rsx! {
                path {
                    d: "M3 3L4.66365 4.66365M21 21L19.5 19.5M14.0153 18.2576L12 17.25L4.5 21V8.74237M4.66365 4.66365C4.95294 3.94962 5.60087 3.41593 6.40668 3.32241C8.24156 3.10947 10.108 3 12 3C13.892 3 15.7584 3.10947 17.5933 3.32241C18.6939 3.45014 19.5 4.399 19.5 5.50699V19.5M4.66365 4.66365L19.5 19.5",
                },
            },
            Shape::BookmarkSquare => rsx! {
                path {
                    d: "M16.5 3.75V16.5L12 14.25L7.5 16.5V3.75M16.5 3.75H18C19.2426 3.75 20.25 4.75736 20.25 6V18C20.25 19.2426 19.2426 20.25 18 20.25H6C4.75736 20.25 3.75 19.2426 3.75 18V6C3.75 4.75736 4.75736 3.75 6 3.75H7.5M16.5 3.75H7.5",
                },
            },
            Shape::Bookmark => rsx! {
                path {
                    d: "M19 21l-7-5-7 5V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z",
                },
            },
            Shape::Box => rsx! {
                path {
                    d: "M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z",
                },
            },
            Shape::Briefcase => rsx! {
                path {
                    d: "M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16",
                },
            },
            Shape::BugAnt => rsx! {
                path {
                    d: "M11.9997 12.75C13.1482 12.75 14.2778 12.8307 15.3833 12.9867C16.4196 13.1329 17.2493 13.9534 17.2493 15C17.2493 18.7279 14.8988 21.75 11.9993 21.75C9.09977 21.75 6.74927 18.7279 6.74927 15C6.74927 13.9535 7.57879 13.1331 8.61502 12.9868C9.72081 12.8307 10.8508 12.75 11.9997 12.75ZM11.9997 12.75C14.8825 12.75 17.6469 13.2583 20.2075 14.1901C20.083 16.2945 19.6873 18.3259 19.0549 20.25M11.9997 12.75C9.11689 12.75 6.35312 13.2583 3.79248 14.1901C3.91702 16.2945 4.31272 18.3259 4.94512 20.25M11.9997 12.75C13.2423 12.75 14.2498 11.7426 14.2498 10.5C14.2498 10.4652 14.249 10.4306 14.2475 10.3961M11.9997 12.75C10.757 12.75 9.74979 11.7426 9.74979 10.5C9.74979 10.4652 9.75058 10.4306 9.75214 10.3961M12.0002 8.25C12.995 8.25 13.971 8.16929 14.922 8.01406C15.3246 7.94835 15.6628 7.65623 15.7168 7.25196C15.7388 7.08776 15.7502 6.92021 15.7502 6.75C15.7502 6.11844 15.594 5.52335 15.3183 5.00121M12.0002 8.25C11.0053 8.25 10.0293 8.16929 9.0783 8.01406C8.67576 7.94835 8.33754 7.65623 8.28346 7.25196C8.26149 7.08777 8.25015 6.92021 8.25015 6.75C8.25015 6.1175 8.40675 5.52157 8.68327 4.99887M12.0002 8.25C10.7923 8.25 9.80641 9.20171 9.75214 10.3961M12.0002 8.25C13.208 8.25 14.1932 9.20171 14.2475 10.3961M8.68327 4.99887C8.25654 4.71496 7.86824 4.37787 7.52783 3.99707C7.59799 3.36615 7.7986 2.7746 8.10206 2.25M8.68327 4.99887C9.31221 3.81004 10.5616 3 12.0002 3C13.4397 3 14.6897 3.8111 15.3183 5.00121M15.3183 5.00121C15.7445 4.71804 16.1325 4.38184 16.4728 4.00201C16.4031 3.36924 16.2023 2.77597 15.898 2.25M4.92097 6C4.71594 7.08086 4.58339 8.18738 4.52856 9.3143C6.19671 9.86025 7.94538 10.2283 9.75214 10.3961M19.0786 6C19.2836 7.08086 19.4162 8.18738 19.471 9.3143C17.8029 9.86024 16.0542 10.2283 14.2475 10.3961",
                },
            },
            Shape::BuildingLibrary => rsx! {
                path {
                    d: "M12 21V12.75M15.75 21V12.75M8.25 21V12.75M3 9L12 3L21 9M19.5 21V10.3325C17.0563 9.94906 14.5514 9.75 12 9.75C9.44861 9.75 6.94372 9.94906 4.5 10.3325V21M3 21H21M12 6.75H12.0075V6.7575H12V6.75Z",
                },
            },
            Shape::BuildingOffice2 => rsx! {
                path {
                    d: "M2.25 21H21.75M3.75 3V21M14.25 3V21M20.25 7.5V21M6.75 6.75H7.5M6.75 9.75H7.5M6.75 12.75H7.5M10.5 6.75H11.25M10.5 9.75H11.25M10.5 12.75H11.25M6.75 21V17.625C6.75 17.0037 7.25368 16.5 7.875 16.5H10.125C10.7463 16.5 11.25 17.0037 11.25 17.625V21M3 3H15M14.25 7.5H21M17.25 11.25H17.2575V11.2575H17.25V11.25ZM17.25 14.25H17.2575V14.2575H17.25V14.25ZM17.25 17.25H17.2575V17.2575H17.25V17.25Z",
                },
            },
            Shape::BuildingOffice => rsx! {
                path {
                    d: "M3.75 21H20.25M4.5 3H19.5M5.25 3V21M18.75 3V21M9 6.75H10.5M9 9.75H10.5M9 12.75H10.5M13.5 6.75H15M13.5 9.75H15M13.5 12.75H15M9 21V17.625C9 17.0037 9.50368 16.5 10.125 16.5H13.875C14.4963 16.5 15 17.0037 15 17.625V21",
                },
            },
            Shape::BuildingStorefront => rsx! {
                path {
                    d: "M13.5 20.9999V13.4999C13.5 13.0856 13.8358 12.7499 14.25 12.7499H17.25C17.6642 12.7499 18 13.0856 18 13.4999V20.9999M13.5 20.9999H2.36088M13.5 20.9999H18M18 20.9999H21.6391M20.25 20.9999V9.34863M3.75 20.9999V9.34888M3.75 9.34888C4.89729 10.012 6.38977 9.85281 7.37132 8.87127C7.41594 8.82665 7.45886 8.78097 7.50008 8.73432C8.04979 9.35708 8.85402 9.74986 9.75 9.74986C10.646 9.74986 11.4503 9.35704 12 8.73423C12.5497 9.35704 13.354 9.74986 14.25 9.74986C15.1459 9.74986 15.9501 9.35713 16.4998 8.73443C16.541 8.78101 16.5838 8.82662 16.6284 8.87118C17.61 9.85281 19.1027 10.012 20.25 9.34863M3.75 9.34888C3.52788 9.2205 3.31871 9.06129 3.12868 8.87127C1.95711 7.69969 1.95711 5.8002 3.12868 4.62863L4.31797 3.43934C4.59927 3.15804 4.9808 3 5.37863 3H18.6212C19.019 3 19.4005 3.15804 19.6818 3.43934L20.871 4.62854C22.0426 5.80011 22.0426 7.69961 20.871 8.87118C20.6811 9.06113 20.472 9.22028 20.25 9.34863M6.75 17.9999H10.5C10.9142 17.9999 11.25 17.6641 11.25 17.2499V13.4999C11.25 13.0856 10.9142 12.7499 10.5 12.7499H6.75C6.33579 12.7499 6 13.0856 6 13.4999V17.2499C6 17.6641 6.33579 17.9999 6.75 17.9999Z",
                },
            },
            Shape::Cake => rsx! {
                path {
                    d: "M12 8.25006V6.75006M12 8.25006C10.6448 8.25006 9.30281 8.30622 7.97608 8.41633C6.84499 8.51021 6 9.47329 6 10.6083V13.1214M12 8.25006C13.3552 8.25006 14.6972 8.30622 16.0239 8.41633C17.155 8.51021 18 9.47329 18 10.6083V13.1214M15 8.25006V6.75006M9 8.25006V6.75006M21 16.5001L19.5 17.2501C18.5557 17.7222 17.4443 17.7222 16.5 17.2501C15.5557 16.7779 14.4443 16.7779 13.5 17.2501C12.5557 17.7222 11.4443 17.7222 10.5 17.2501C9.55573 16.7779 8.44427 16.7779 7.5 17.2501C6.55573 17.7222 5.44427 17.7222 4.5 17.2501L3 16.5001M18 13.1214C16.0344 12.8763 14.032 12.7501 12 12.7501C9.96804 12.7501 7.96557 12.8763 6 13.1214M18 13.1214C18.3891 13.1699 18.7768 13.2231 19.163 13.2809C20.2321 13.4409 21 14.3748 21 15.4557V20.6251C21 21.2464 20.4963 21.7501 19.875 21.7501H4.125C3.50368 21.7501 3 21.2464 3 20.6251V15.4557C3 14.3748 3.76793 13.4409 4.83697 13.2809C5.22316 13.2231 5.61086 13.1699 6 13.1214M12.2652 3.10989C12.4117 3.25634 12.4117 3.49378 12.2652 3.64022C12.1188 3.78667 11.8813 3.78667 11.7349 3.64022C11.5884 3.49378 11.5884 3.25634 11.7349 3.10989C11.8104 3.03435 12.0001 2.84473 12.0001 2.84473C12.0001 2.84473 12.1943 3.039 12.2652 3.10989ZM9.26522 3.10989C9.41167 3.25634 9.41167 3.49378 9.26522 3.64022C9.11878 3.78667 8.88134 3.78667 8.73489 3.64022C8.58844 3.49378 8.58844 3.25634 8.73489 3.10989C8.81044 3.03435 9.00005 2.84473 9.00005 2.84473C9.00005 2.84473 9.19432 3.039 9.26522 3.10989ZM15.2652 3.10989C15.4117 3.25634 15.4117 3.49378 15.2652 3.64022C15.1188 3.78667 14.8813 3.78667 14.7349 3.64022C14.5884 3.49378 14.5884 3.25634 14.7349 3.10989C14.8104 3.03435 15.0001 2.84473 15.0001 2.84473C15.0001 2.84473 15.1943 3.039 15.2652 3.10989Z",
                },
            },
            Shape::Calculator => rsx! {
                path {
                    d: "M15.75 15.75V18M8.25 11.25H8.2575V11.2575H8.25V11.25ZM8.25 13.5H8.2575V13.5075H8.25V13.5ZM8.25 15.75H8.2575V15.7575H8.25V15.75ZM8.25 18H8.2575V18.0075H8.25V18ZM10.7476 11.25H10.7551V11.2575H10.7476V11.25ZM10.7476 13.5H10.7551V13.5075H10.7476V13.5ZM10.7476 15.75H10.7551V15.7575H10.7476V15.75ZM10.7476 18H10.7551V18.0075H10.7476V18ZM13.2524 11.25H13.2599V11.2575H13.2524V11.25ZM13.2524 13.5H13.2599V13.5075H13.2524V13.5ZM13.2524 15.75H13.2599V15.7575H13.2524V15.75ZM13.2524 18H13.2599V18.0075H13.2524V18ZM15.75 11.25H15.7575V11.2575H15.75V11.25ZM15.75 13.5H15.7575V13.5075H15.75V13.5ZM8.25 6H15.75V8.25H8.25V6ZM12 2.25C10.108 2.25 8.24156 2.35947 6.40668 2.57241C5.30608 2.70014 4.5 3.649 4.5 4.75699V19.5C4.5 20.7426 5.50736 21.75 6.75 21.75H17.25C18.4926 21.75 19.5 20.7426 19.5 19.5V4.75699C19.5 3.649 18.6939 2.70014 17.5933 2.57241C15.7584 2.35947 13.892 2.25 12 2.25Z",
                },
            },
            Shape::CalendarDays => rsx! {
                path {
                    d: "M6.75 3V5.25M17.25 3V5.25M3 18.75V7.5C3 6.25736 4.00736 5.25 5.25 5.25H18.75C19.9926 5.25 21 6.25736 21 7.5V18.75M3 18.75C3 19.9926 4.00736 21 5.25 21H18.75C19.9926 21 21 19.9926 21 18.75M3 18.75V11.25C3 10.0074 4.00736 9 5.25 9H18.75C19.9926 9 21 10.0074 21 11.25V18.75M12 12.75H12.0075V12.7575H12V12.75ZM12 15H12.0075V15.0075H12V15ZM12 17.25H12.0075V17.2575H12V17.25ZM9.75 15H9.7575V15.0075H9.75V15ZM9.75 17.25H9.7575V17.2575H9.75V17.25ZM7.5 15H7.5075V15.0075H7.5V15ZM7.5 17.25H7.5075V17.2575H7.5V17.25ZM14.25 12.75H14.2575V12.7575H14.25V12.75ZM14.25 15H14.2575V15.0075H14.25V15ZM14.25 17.25H14.2575V17.2575H14.25V17.25ZM16.5 12.75H16.5075V12.7575H16.5V12.75ZM16.5 15H16.5075V15.0075H16.5V15Z",
                },
            },
            Shape::Calendar => rsx! {
                path {
                    d: "",
                },
            },
            Shape::CameraOff => rsx! {
                path {
                    d: "M21 21H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h3m3-3h6l2 3h4a2 2 0 0 1 2 2v9.34m-7.72-2.06a4 4 0 1 1-5.56-5.56",
                },
            },
            Shape::Camera => rsx! {
                path {
                    d: "M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z",
                },
            },
            Shape::Cast => rsx! {
                path {
                    d: "M2 16.1A5 5 0 0 1 5.9 20M2 12.05A9 9 0 0 1 9.95 20M2 8V6a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-6",
                },
            },
            Shape::ChartBarSquare => rsx! {
                path {
                    d: "M7.5 14.25V16.5M10.5 12V16.5M13.5 9.75V16.5M16.5 7.5V16.5M6 20.25H18C19.2426 20.25 20.25 19.2426 20.25 18V6C20.25 4.75736 19.2426 3.75 18 3.75H6C4.75736 3.75 3.75 4.75736 3.75 6V18C3.75 19.2426 4.75736 20.25 6 20.25Z",
                },
            },
            Shape::ChartBar => rsx! {
                path {
                    d: "M3 13.125C3 12.5037 3.50368 12 4.125 12H6.375C6.99632 12 7.5 12.5037 7.5 13.125V19.875C7.5 20.4963 6.99632 21 6.375 21H4.125C3.50368 21 3 20.4963 3 19.875V13.125Z M9.75 8.625C9.75 8.00368 10.2537 7.5 10.875 7.5H13.125C13.7463 7.5 14.25 8.00368 14.25 8.625V19.875C14.25 20.4963 13.7463 21 13.125 21H10.875C10.2537 21 9.75 20.4963 9.75 19.875V8.625Z M16.5 4.125C16.5 3.50368 17.0037 3 17.625 3H19.875C20.4963 3 21 3.50368 21 4.125V19.875C21 20.4963 20.4963 21 19.875 21H17.625C17.0037 21 16.5 20.4963 16.5 19.875V4.125Z",
                },
            },
            Shape::ChartPie => rsx! {
                path {
                    d: "M10.5 6C6.35786 6 3 9.35786 3 13.5C3 17.6421 6.35786 21 10.5 21C14.6421 21 18 17.6421 18 13.5H10.5V6Z M13.5 10.5H21C21 6.35786 17.6421 3 13.5 3V10.5Z",
                },
            },
            Shape::ChatBubbleBottomCenterText => rsx! {
                path {
                    d: "M7.5 8.25H16.5M7.5 11.25H12M2.25 12.7593C2.25 14.3604 3.37341 15.754 4.95746 15.987C6.08596 16.1529 7.22724 16.2796 8.37985 16.3655C8.73004 16.3916 9.05017 16.5753 9.24496 16.8674L12 21L14.755 16.8675C14.9498 16.5753 15.2699 16.3917 15.6201 16.3656C16.7727 16.2796 17.914 16.153 19.0425 15.9871C20.6266 15.7542 21.75 14.3606 21.75 12.7595V6.74056C21.75 5.13946 20.6266 3.74583 19.0425 3.51293C16.744 3.17501 14.3926 3 12.0003 3C9.60776 3 7.25612 3.17504 4.95747 3.51302C3.37342 3.74593 2.25 5.13956 2.25 6.74064V12.7593Z",
                },
            },
            Shape::ChatBubbleBottomCenter => rsx! {
                path {
                    d: "M2.25 12.7593C2.25 14.3604 3.37341 15.754 4.95746 15.987C6.02548 16.144 7.10495 16.2659 8.19464 16.3513C8.66142 16.388 9.08828 16.6324 9.348 17.022L12 21L14.652 17.0221C14.9117 16.6325 15.3386 16.388 15.8053 16.3514C16.895 16.2659 17.9745 16.1441 19.0425 15.9871C20.6266 15.7542 21.75 14.3606 21.75 12.7595V6.74056C21.75 5.13946 20.6266 3.74583 19.0425 3.51293C16.744 3.17501 14.3926 3 12.0003 3C9.60776 3 7.25612 3.17504 4.95747 3.51302C3.37342 3.74593 2.25 5.13956 2.25 6.74064V12.7593Z",
                },
            },
            Shape::ChatBubbleLeftEllipsis => rsx! {
                path {
                    d: "M8.625 9.75C8.625 9.95711 8.45711 10.125 8.25 10.125C8.04289 10.125 7.875 9.95711 7.875 9.75C7.875 9.54289 8.04289 9.375 8.25 9.375C8.45711 9.375 8.625 9.54289 8.625 9.75ZM8.625 9.75H8.25M12.375 9.75C12.375 9.95711 12.2071 10.125 12 10.125C11.7929 10.125 11.625 9.95711 11.625 9.75C11.625 9.54289 11.7929 9.375 12 9.375C12.2071 9.375 12.375 9.54289 12.375 9.75ZM12.375 9.75H12M16.125 9.75C16.125 9.95711 15.9571 10.125 15.75 10.125C15.5429 10.125 15.375 9.95711 15.375 9.75C15.375 9.54289 15.5429 9.375 15.75 9.375C15.9571 9.375 16.125 9.54289 16.125 9.75ZM16.125 9.75H15.75M2.25 12.7593C2.25 14.3604 3.37341 15.754 4.95746 15.987C6.04357 16.1467 7.14151 16.27 8.25 16.3556V21L12.4335 16.8165C12.6402 16.6098 12.9193 16.4923 13.2116 16.485C15.1872 16.4361 17.1331 16.2678 19.0425 15.9871C20.6266 15.7542 21.75 14.3606 21.75 12.7595V6.74056C21.75 5.13946 20.6266 3.74583 19.0425 3.51293C16.744 3.17501 14.3926 3 12.0003 3C9.60776 3 7.25612 3.17504 4.95747 3.51302C3.37342 3.74593 2.25 5.13956 2.25 6.74064V12.7593Z",
                },
            },
            Shape::ChatBubbleLeftRight => rsx! {
                path {
                    d: "M20.25 8.51104C21.1341 8.79549 21.75 9.6392 21.75 10.6082V14.8938C21.75 16.0304 20.9026 16.9943 19.7697 17.0867C19.4308 17.1144 19.0909 17.1386 18.75 17.1592V20.25L15.75 17.25C14.3963 17.25 13.0556 17.1948 11.7302 17.0866C11.4319 17.0623 11.1534 16.9775 10.9049 16.8451M20.25 8.51104C20.0986 8.46232 19.9393 8.43 19.7739 8.41628C18.4472 8.30616 17.1051 8.25 15.75 8.25C14.3948 8.25 13.0528 8.30616 11.7261 8.41627C10.595 8.51015 9.75 9.47323 9.75 10.6082V14.8937C9.75 15.731 10.2099 16.4746 10.9049 16.8451M20.25 8.51104V6.63731C20.25 5.01589 19.0983 3.61065 17.4903 3.40191C15.4478 3.13676 13.365 3 11.2503 3C9.13533 3 7.05233 3.13678 5.00963 3.40199C3.40173 3.61074 2.25 5.01598 2.25 6.63738V12.8626C2.25 14.484 3.40173 15.8893 5.00964 16.098C5.58661 16.1729 6.16679 16.2376 6.75 16.2918V21L10.9049 16.8451",
                },
            },
            Shape::ChatBubbleLeft => rsx! {
                path {
                    d: "M2.25 12.7593C2.25 14.3604 3.37341 15.754 4.95746 15.987C6.04357 16.1467 7.14151 16.27 8.25 16.3556V21L12.326 16.924C12.6017 16.6483 12.9738 16.4919 13.3635 16.481C15.2869 16.4274 17.1821 16.2606 19.0425 15.9871C20.6266 15.7542 21.75 14.3606 21.75 12.7595V6.74056C21.75 5.13946 20.6266 3.74583 19.0425 3.51293C16.744 3.17501 14.3926 3 12.0003 3C9.60776 3 7.25612 3.17504 4.95747 3.51302C3.37342 3.74593 2.25 5.13956 2.25 6.74064V12.7593Z",
                },
            },
            Shape::ChatBubbleOvalLeftEllipsis => rsx! {
                path {
                    d: "M8.625 12C8.625 12.2071 8.45711 12.375 8.25 12.375C8.04289 12.375 7.875 12.2071 7.875 12C7.875 11.7929 8.04289 11.625 8.25 11.625C8.45711 11.625 8.625 11.7929 8.625 12ZM8.625 12H8.25M12.375 12C12.375 12.2071 12.2071 12.375 12 12.375C11.7929 12.375 11.625 12.2071 11.625 12C11.625 11.7929 11.7929 11.625 12 11.625C12.2071 11.625 12.375 11.7929 12.375 12ZM12.375 12H12M16.125 12C16.125 12.2071 15.9571 12.375 15.75 12.375C15.5429 12.375 15.375 12.2071 15.375 12C15.375 11.7929 15.5429 11.625 15.75 11.625C15.9571 11.625 16.125 11.7929 16.125 12ZM16.125 12H15.75M21 12C21 16.5563 16.9706 20.25 12 20.25C11.1125 20.25 10.2551 20.1323 9.44517 19.9129C8.47016 20.5979 7.28201 21 6 21C5.80078 21 5.60376 20.9903 5.40967 20.9713C5.25 20.9558 5.0918 20.9339 4.93579 20.906C5.41932 20.3353 5.76277 19.6427 5.91389 18.8808C6.00454 18.4238 5.7807 17.9799 5.44684 17.6549C3.9297 16.1782 3 14.1886 3 12C3 7.44365 7.02944 3.75 12 3.75C16.9706 3.75 21 7.44365 21 12Z",
                },
            },
            Shape::ChatBubbleOvalLeft => rsx! {
                path {
                    d: "M12 20.25C16.9706 20.25 21 16.5563 21 12C21 7.44365 16.9706 3.75 12 3.75C7.02944 3.75 3 7.44365 3 12C3 14.1036 3.85891 16.0234 5.2728 17.4806C5.70538 17.9265 6.01357 18.5192 5.85933 19.121C5.68829 19.7883 5.368 20.3959 4.93579 20.906C5.0918 20.9339 5.25 20.9558 5.40967 20.9713C5.60376 20.9903 5.80078 21 6 21C7.28201 21 8.47016 20.5979 9.44517 19.9129C10.2551 20.1323 11.1125 20.25 12 20.25Z",
                },
            },
            Shape::ChatPlus => rsx! {
                path {
                    d: " M 7.19 8.92 L 16.19 8.92 M 7.19 11.92 L 11.69 11.92 M 15.91 3.85 C 14.51 3.73 13.1 3.67 11.69 3.67 C 9.3 3.67 6.95 3.84 4.65 4.18 C 3.07 4.41 1.94 5.81 1.94 7.41 L 1.94 13.43 L 1.94 13.43 C 1.94 15.03 3.06 16.42 4.65 16.66 C 5.78 16.83 6.92 16.95 8.07 17.04 C 8.42 17.07 8.74 17.25 8.93 17.54 L 11.69 21.67 L 14.45 17.54 C 14.55 17.4 14.67 17.28 14.82 17.19 C 14.97 17.1 15.14 17.05 15.31 17.04 C 16.46 16.95 17.6 16.83 18.73 16.66 C 20.31 16.43 21.44 15.03 21.44 13.43 L 21.44 8.56 M 18.06 2.33 L 18.06 6.33 M 18.06 6.33 L 18.06 10.33 M 18.06 6.33 L 22.06 6.33 M 18.06 6.33 L 14.06 6.33",
                },
            },
            Shape::ChatSlash => rsx! {
                path {
                    d: " M 9.11 8.755 L 16.49 8.755 M 7.49 11.755 L 9.11 11.755 M 16.99 16.745 C 17.71 16.675 18.33 16.595 19.04 16.485 C 20.62 16.255 21.75 14.855 21.75 13.255 L 21.75 7.235 C 21.75 5.635 20.63 4.235 19.04 4.005 C 16.71 3.665 14.35 3.495 12 3.495 C 9.61 3.495 7.26 3.665 4.96 4.005 C 4.78 4.035 4.6 4.075 4.43 4.125 M 2.83 5.345 C 2.46 5.885 2.25 6.535 2.25 7.235 L 2.25 13.255 L 2.25 13.255 C 2.25 14.855 3.37 16.245 4.96 16.485 C 6.09 16.655 7.23 16.775 8.38 16.865 C 8.73 16.895 9.05 17.075 9.24 17.365 L 12 21.495 L 14.76 17.365 M 2.74 2.505 L 20.15 19.915",
                },
            },
            Shape::CheckBadge => rsx! {
                path {
                    d: "M9 12.75L11.25 15L15 9.75M21 12C21 13.2683 20.3704 14.3895 19.4067 15.0682C19.6081 16.2294 19.2604 17.4672 18.3637 18.3639C17.467 19.2606 16.2292 19.6083 15.068 19.4069C14.3893 20.3705 13.2682 21 12 21C10.7319 21 9.61072 20.3705 8.93204 19.407C7.77066 19.6086 6.53256 19.261 5.6357 18.3641C4.73886 17.4673 4.39125 16.2292 4.59286 15.0678C3.62941 14.3891 3 13.2681 3 12C3 10.7319 3.62946 9.61077 4.59298 8.93208C4.39147 7.77079 4.7391 6.53284 5.63587 5.63607C6.53265 4.73929 7.77063 4.39166 8.93194 4.59319C9.61061 3.62955 10.7318 3 12 3C13.2682 3 14.3893 3.6295 15.068 4.59307C16.2294 4.39145 17.4674 4.73906 18.3643 5.6359C19.2611 6.53274 19.6087 7.77081 19.4071 8.93218C20.3706 9.61087 21 10.7319 21 12Z",
                },
            },
            Shape::CheckCircle => rsx! {
                path {
                    d: "M22 11.08V12a10 10 0 1 1-5.93-9.14",
                },
            },
            Shape::CheckSquare => rsx! {
                path {
                    d: "M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11",
                },
            },
            Shape::Check => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ChevronDoubleDown => rsx! {
                path {
                    d: "M19.5 5.25L12 12.75L4.5 5.25M19.5 11.25L12 18.75L4.5 11.25",
                },
            },
            Shape::ChevronDoubleLeft => rsx! {
                path {
                    d: "M18.75 19.5L11.25 12L18.75 4.5M12.75 19.5L5.25 12L12.75 4.5",
                },
            },
            Shape::ChevronDoubleRight => rsx! {
                path {
                    d: "M11.25 4.5L18.75 12L11.25 19.5M5.25 4.5L12.75 12L5.25 19.5",
                },
            },
            Shape::ChevronDoubleUp => rsx! {
                path {
                    d: "M4.5 12.75L12 5.25L19.5 12.75M4.5 18.75L12 11.25L19.5 18.75",
                },
            },
            Shape::ChevronDown => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ChevronLeft => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ChevronRight => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ChevronUpDown => rsx! {
                path {
                    d: "M8.25 15L12 18.75L15.75 15M8.25 9L12 5.25L15.75 9",
                },
            },
            Shape::ChevronUp => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ChevronsDown => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ChevronsLeft => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ChevronsRight => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ChevronsUp => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Chrome => rsx! {
                path {
                    d: "",
                },
            },
            Shape::CircleStack => rsx! {
                path {
                    d: "M20.25 6.375C20.25 8.65317 16.5563 10.5 12 10.5C7.44365 10.5 3.75 8.65317 3.75 6.375M20.25 6.375C20.25 4.09683 16.5563 2.25 12 2.25C7.44365 2.25 3.75 4.09683 3.75 6.375M20.25 6.375V17.625C20.25 19.9032 16.5563 21.75 12 21.75C7.44365 21.75 3.75 19.9032 3.75 17.625V6.375M20.25 6.375V10.125M3.75 6.375V10.125M20.25 10.125V13.875C20.25 16.1532 16.5563 18 12 18C7.44365 18 3.75 16.1532 3.75 13.875V10.125M20.25 10.125C20.25 12.4032 16.5563 14.25 12 14.25C7.44365 14.25 3.75 12.4032 3.75 10.125",
                },
            },
            Shape::Circle => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ClipboardDocumentCheck => rsx! {
                path {
                    d: "M11.3495 3.83619C11.2848 4.04602 11.25 4.26894 11.25 4.5C11.25 4.91421 11.5858 5.25 12 5.25H16.5C16.9142 5.25 17.25 4.91421 17.25 4.5C17.25 4.26894 17.2152 4.04602 17.1505 3.83619M11.3495 3.83619C11.6328 2.91757 12.4884 2.25 13.5 2.25H15C16.0116 2.25 16.8672 2.91757 17.1505 3.83619M11.3495 3.83619C10.9739 3.85858 10.5994 3.88529 10.2261 3.91627C9.09499 4.01015 8.25 4.97324 8.25 6.10822V8.25M17.1505 3.83619C17.5261 3.85858 17.9006 3.88529 18.2739 3.91627C19.405 4.01015 20.25 4.97324 20.25 6.10822V16.5C20.25 17.7426 19.2426 18.75 18 18.75H15.75M8.25 8.25H4.875C4.25368 8.25 3.75 8.75368 3.75 9.375V20.625C3.75 21.2463 4.25368 21.75 4.875 21.75H14.625C15.2463 21.75 15.75 21.2463 15.75 20.625V18.75M8.25 8.25H14.625C15.2463 8.25 15.75 8.75368 15.75 9.375V18.75M7.5 15.75L9 17.25L12 13.5",
                },
            },
            Shape::ClipboardDocumentList => rsx! {
                path {
                    d: "M9 12H12.75M9 15H12.75M9 18H12.75M15.75 18.75H18C19.2426 18.75 20.25 17.7426 20.25 16.5V6.10822C20.25 4.97324 19.405 4.01015 18.2739 3.91627C17.9006 3.88529 17.5261 3.85858 17.1505 3.83619M11.3495 3.83619C11.2848 4.04602 11.25 4.26894 11.25 4.5C11.25 4.91421 11.5858 5.25 12 5.25H16.5C16.9142 5.25 17.25 4.91421 17.25 4.5C17.25 4.26894 17.2152 4.04602 17.1505 3.83619M11.3495 3.83619C11.6328 2.91757 12.4884 2.25 13.5 2.25H15C16.0116 2.25 16.8672 2.91757 17.1505 3.83619M11.3495 3.83619C10.9739 3.85858 10.5994 3.88529 10.2261 3.91627C9.09499 4.01015 8.25 4.97324 8.25 6.10822V8.25M8.25 8.25H4.875C4.25368 8.25 3.75 8.75368 3.75 9.375V20.625C3.75 21.2463 4.25368 21.75 4.875 21.75H14.625C15.2463 21.75 15.75 21.2463 15.75 20.625V9.375C15.75 8.75368 15.2463 8.25 14.625 8.25H8.25ZM6.75 12H6.7575V12.0075H6.75V12ZM6.75 15H6.7575V15.0075H6.75V15ZM6.75 18H6.7575V18.0075H6.75V18Z",
                },
            },
            Shape::ClipboardDocument => rsx! {
                path {
                    d: "M8.25 7.5V6.10822C8.25 4.97324 9.09499 4.01015 10.2261 3.91627C10.5994 3.88529 10.9739 3.85858 11.3495 3.83619M15.75 18H18C19.2426 18 20.25 16.9926 20.25 15.75V6.10822C20.25 4.97324 19.405 4.01015 18.2739 3.91627C17.9006 3.88529 17.5261 3.85858 17.1505 3.83619M15.75 18.75V16.875C15.75 15.011 14.239 13.5 12.375 13.5H10.875C10.2537 13.5 9.75 12.9963 9.75 12.375V10.875C9.75 9.01104 8.23896 7.5 6.375 7.5H5.25M17.1505 3.83619C16.8672 2.91757 16.0116 2.25 15 2.25H13.5C12.4884 2.25 11.6328 2.91757 11.3495 3.83619M17.1505 3.83619C17.2152 4.04602 17.25 4.26894 17.25 4.5V5.25H11.25V4.5C11.25 4.26894 11.2848 4.04602 11.3495 3.83619M6.75 7.5H4.875C4.25368 7.5 3.75 8.00368 3.75 8.625V20.625C3.75 21.2463 4.25368 21.75 4.875 21.75H14.625C15.2463 21.75 15.75 21.2463 15.75 20.625V16.5C15.75 11.5294 11.7206 7.5 6.75 7.5Z",
                },
            },
            Shape::Clipboard => rsx! {
                path {
                    d: "M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2",
                },
            },
            Shape::Clock => rsx! {
                path {
                    d: "",
                },
            },
            Shape::CloudArrowDown => rsx! {
                path {
                    d: "M12 9.75V16.5M12 16.5L9 13.5M12 16.5L15 13.5M6.75 19.5C4.26472 19.5 2.25 17.4853 2.25 15C2.25 13.0071 3.54555 11.3167 5.3404 10.7252C5.28105 10.4092 5.25 10.0832 5.25 9.75C5.25 6.85051 7.60051 4.5 10.5 4.5C12.9312 4.5 14.9765 6.1526 15.5737 8.39575C15.8654 8.30113 16.1767 8.25 16.5 8.25C18.1569 8.25 19.5 9.59315 19.5 11.25C19.5 11.5981 19.4407 11.9324 19.3316 12.2433C20.7453 12.7805 21.75 14.1479 21.75 15.75C21.75 17.8211 20.0711 19.5 18 19.5H6.75Z",
                },
            },
            Shape::CloudArrowUp => rsx! {
                path {
                    d: "M12 16.5L12 9.75M12 9.75L15 12.75M12 9.75L9 12.75M6.75 19.5C4.26472 19.5 2.25 17.4853 2.25 15C2.25 13.0071 3.54555 11.3167 5.3404 10.7252C5.28105 10.4092 5.25 10.0832 5.25 9.75C5.25 6.85051 7.60051 4.5 10.5 4.5C12.9312 4.5 14.9765 6.1526 15.5737 8.39575C15.8654 8.30113 16.1767 8.25 16.5 8.25C18.1569 8.25 19.5 9.59315 19.5 11.25C19.5 11.5981 19.4407 11.9324 19.3316 12.2433C20.7453 12.7805 21.75 14.1479 21.75 15.75C21.75 17.8211 20.0711 19.5 18 19.5H6.75Z",
                },
            },
            Shape::CloudDrizzle => rsx! {
                path {
                    d: "M20 16.58A5 5 0 0 0 18 7h-1.26A8 8 0 1 0 4 15.25",
                },
            },
            Shape::CloudLightning => rsx! {
                path {
                    d: "M19 16.9A5 5 0 0 0 18 7h-1.26a8 8 0 1 0-11.62 9",
                },
            },
            Shape::CloudOff => rsx! {
                path {
                    d: "M22.61 16.95A5 5 0 0 0 18 10h-1.26a8 8 0 0 0-7.05-6M5 5a8 8 0 0 0 4 15h9a5 5 0 0 0 1.7-.3",
                },
            },
            Shape::CloudRain => rsx! {
                path {
                    d: "M20 16.58A5 5 0 0 0 18 7h-1.26A8 8 0 1 0 4 15.25",
                },
            },
            Shape::CloudSnow => rsx! {
                path {
                    d: "M20 17.58A5 5 0 0 0 18 8h-1.26A8 8 0 1 0 4 16.25",
                },
            },
            Shape::Cloud => rsx! {
                path {
                    d: "M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z",
                },
            },
            Shape::CodeBracketSquare => rsx! {
                path {
                    d: "M14.25 9.75L16.5 12L14.25 14.25M9.75 14.25L7.5 12L9.75 9.75M6 20.25H18C19.2426 20.25 20.25 19.2426 20.25 18V6C20.25 4.75736 19.2426 3.75 18 3.75H6C4.75736 3.75 3.75 4.75736 3.75 6V18C3.75 19.2426 4.75736 20.25 6 20.25Z",
                },
            },
            Shape::CodeBracket => rsx! {
                path {
                    d: "M17.25 6.75L22.5 12L17.25 17.25M6.75 17.25L1.5 12L6.75 6.75M14.25 3.75L9.75 20.25",
                },
            },
            Shape::Code => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Codepen => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Codesandbox => rsx! {
                path {
                    d: "M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z",
                },
            },
            Shape::Coffee => rsx! {
                path {
                    d: "M18 8h1a4 4 0 0 1 0 8h-1 M2 8h16v9a4 4 0 0 1-4 4H6a4 4 0 0 1-4-4V8z",
                },
            },
            Shape::Cog6Tooth => rsx! {
                path {
                    d: "M9.59353 3.94005C9.68394 3.39759 10.1533 3 10.7032 3H13.2972C13.8471 3 14.3165 3.39759 14.4069 3.94005L14.6204 5.2211C14.6827 5.59514 14.9327 5.90671 15.2645 6.09036C15.3386 6.13142 15.412 6.17383 15.4844 6.21757C15.8094 6.41384 16.2048 6.47486 16.5603 6.34166L17.7772 5.88578C18.2922 5.69284 18.8712 5.90051 19.1461 6.37677L20.4431 8.62321C20.7181 9.09948 20.6084 9.70473 20.1839 10.0543L19.1795 10.8811C18.887 11.1219 18.742 11.4937 18.749 11.8725C18.7498 11.9149 18.7502 11.9574 18.7502 12C18.7502 12.0426 18.7498 12.0851 18.749 12.1275C18.742 12.5063 18.887 12.8781 19.1795 13.1189L20.1839 13.9457C20.6084 14.2953 20.7181 14.9005 20.4431 15.3768L19.1461 17.6232C18.8712 18.0995 18.2922 18.3071 17.7772 18.1142L16.5603 17.6583C16.2048 17.5251 15.8094 17.5862 15.4844 17.7824C15.412 17.8262 15.3386 17.8686 15.2645 17.9096C14.9327 18.0933 14.6827 18.4049 14.6204 18.7789L14.4069 20.0599C14.3165 20.6024 13.8471 21 13.2972 21H10.7032C10.1533 21 9.68394 20.6024 9.59353 20.0599L9.38002 18.7789C9.31768 18.4049 9.06771 18.0933 8.73594 17.9096C8.66176 17.8686 8.58844 17.8262 8.51601 17.7824C8.19098 17.5862 7.79565 17.5251 7.44008 17.6583L6.22322 18.1142C5.70822 18.3072 5.12923 18.0995 4.85426 17.6232L3.55728 15.3768C3.28231 14.9005 3.39196 14.2953 3.81654 13.9457L4.82089 13.1189C5.1134 12.8781 5.2584 12.5063 5.25138 12.1275C5.2506 12.0851 5.2502 12.0426 5.2502 12C5.2502 11.9574 5.2506 11.9149 5.25138 11.8725C5.2584 11.4937 5.1134 11.1219 4.82089 10.8811L3.81654 10.0543C3.39196 9.70475 3.28231 9.09949 3.55728 8.62323L4.85426 6.37679C5.12923 5.90052 5.70822 5.69286 6.22321 5.88579L7.44007 6.34167C7.79563 6.47487 8.19096 6.41385 8.516 6.21758C8.58843 6.17384 8.66176 6.13142 8.73594 6.09036C9.06771 5.90671 9.31768 5.59514 9.38002 5.2211L9.59353 3.94005Z M15 11.9999C15 13.6568 13.6568 14.9999 12 14.9999C10.3431 14.9999 8.99997 13.6568 8.99997 11.9999C8.99997 10.3431 10.3431 8.99992 12 8.99992C13.6568 8.99992 15 10.3431 15 11.9999Z",
                },
            },
            Shape::Cog8Tooth => rsx! {
                path {
                    d: "M10.3427 3.94005C10.4331 3.39759 10.9024 3 11.4523 3H12.5463C13.0963 3 13.5656 3.39759 13.656 3.94005L13.805 4.83386C13.8757 5.25813 14.1886 5.59838 14.5859 5.76332C14.9833 5.92832 15.4396 5.90629 15.7898 5.65617L16.5273 5.12933C16.9749 4.80969 17.5879 4.86042 17.9767 5.24929L18.7503 6.02284C19.1392 6.41171 19.1899 7.02472 18.8702 7.47223L18.3432 8.21007C18.0932 8.56012 18.0711 9.01633 18.2361 9.41363C18.401 9.81078 18.7411 10.1236 19.1653 10.1943L20.0593 10.3433C20.6017 10.4337 20.9993 10.9031 20.9993 11.453V12.547C20.9993 13.0969 20.6017 13.5663 20.0593 13.6567L19.1655 13.8056C18.7412 13.8764 18.4009 14.1893 18.236 14.5865C18.071 14.9839 18.0931 15.4403 18.3432 15.7904L18.8699 16.5278C19.1895 16.9753 19.1388 17.5884 18.7499 17.9772L17.9764 18.7508C17.5875 19.1396 16.9745 19.1904 16.527 18.8707L15.7894 18.3439C15.4393 18.0938 14.9831 18.0718 14.5857 18.2367C14.1886 18.4016 13.8757 18.7418 13.805 19.166L13.656 20.0599C13.5656 20.6024 13.0963 21 12.5463 21H11.4523C10.9024 21 10.4331 20.6024 10.3427 20.0599L10.1937 19.1661C10.123 18.7419 9.81005 18.4016 9.41282 18.2367C9.01541 18.0717 8.55908 18.0937 8.20893 18.3438L7.47131 18.8707C7.0238 19.1904 6.41079 19.1396 6.02192 18.7507L5.24837 17.9772C4.8595 17.5883 4.80877 16.9753 5.12842 16.5278L5.65545 15.79C5.90549 15.4399 5.92754 14.9837 5.76258 14.5864C5.5977 14.1892 5.25752 13.8764 4.83335 13.8057L3.93938 13.6567C3.39692 13.5663 2.99933 13.0969 2.99933 12.547V11.453C2.99933 10.9031 3.39692 10.4337 3.93938 10.3433L4.83319 10.1944C5.25746 10.1236 5.59771 9.81071 5.76265 9.41347C5.92766 9.01605 5.90562 8.5597 5.6555 8.20954L5.12881 7.47216C4.80916 7.02465 4.85989 6.41164 5.24876 6.02277L6.02231 5.24922C6.41118 4.86036 7.02419 4.80962 7.4717 5.12927L8.2093 5.65613C8.55937 5.90618 9.01561 5.92822 9.41293 5.76326C9.8101 5.59837 10.123 5.25819 10.1937 4.834L10.3427 3.94005Z M15 12C15 13.6569 13.6569 15 12 15C10.3432 15 9.00003 13.6569 9.00003 12C9.00003 10.3432 10.3432 9.00002 12 9.00002C13.6569 9.00002 15 10.3432 15 12Z",
                },
            },
            Shape::Cog => rsx! {
                path {
                    d: "M4.50073 11.9993C4.50073 16.1414 7.8586 19.4993 12.0007 19.4993C16.1429 19.4993 19.5007 16.1414 19.5007 11.9993M4.50073 11.9993C4.50073 7.85712 7.8586 4.49925 12.0007 4.49925C16.1429 4.49926 19.5007 7.85712 19.5007 11.9993M4.50073 11.9993L3.00073 11.9993M19.5007 11.9993L21.0007 11.9993M19.5007 11.9993L12.0007 11.9993M3.54329 15.0774L4.95283 14.5644M19.0482 9.43411L20.4578 8.92108M5.1062 17.785L6.25527 16.8208M17.7459 7.17897L18.895 6.21479M7.50064 19.7943L8.25064 18.4952M15.7506 5.50484L16.5006 4.2058M10.4378 20.8633L10.6983 19.386M13.303 4.61393L13.5635 3.13672M13.5635 20.8633L13.303 19.3861M10.6983 4.61397L10.4378 3.13676M16.5007 19.7941L15.7507 18.4951M7.50068 4.20565L12.0007 11.9993M18.8952 17.7843L17.7461 16.8202M6.25542 7.17835L5.10635 6.21417M20.458 15.0776L19.0485 14.5646M4.95308 9.43426L3.54354 8.92123M12.0007 11.9993L8.25073 18.4944",
                },
            },
            Shape::Columns => rsx! {
                path {
                    d: "M12 3h7a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-7m0-18H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h7m0-18v18",
                },
            },
            Shape::CommandLine => rsx! {
                path {
                    d: "M6.75 7.5L9.75 9.75L6.75 12M11.25 12H14.25M5.25 20.25H18.75C19.9926 20.25 21 19.2426 21 18V6C21 4.75736 19.9926 3.75 18.75 3.75H5.25C4.00736 3.75 3 4.75736 3 6V18C3 19.2426 4.00736 20.25 5.25 20.25Z",
                },
            },
            Shape::Command => rsx! {
                path {
                    d: "M18 3a3 3 0 0 0-3 3v12a3 3 0 0 0 3 3 3 3 0 0 0 3-3 3 3 0 0 0-3-3H6a3 3 0 0 0-3 3 3 3 0 0 0 3 3 3 3 0 0 0 3-3V6a3 3 0 0 0-3-3 3 3 0 0 0-3 3 3 3 0 0 0 3 3h12a3 3 0 0 0 3-3 3 3 0 0 0-3-3z",
                },
            },
            Shape::Compass => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ComputerDesktop => rsx! {
                path {
                    d: "M9 17.25V18.2574C9 19.053 8.68393 19.8161 8.12132 20.3787L7.5 21H16.5L15.8787 20.3787C15.3161 19.8161 15 19.053 15 18.2574V17.25M21 5.25V15C21 16.2426 19.9926 17.25 18.75 17.25H5.25C4.00736 17.25 3 16.2426 3 15V5.25M21 5.25C21 4.00736 19.9926 3 18.75 3H5.25C4.00736 3 3 4.00736 3 5.25M21 5.25V12C21 13.2426 19.9926 14.25 18.75 14.25H5.25C4.00736 14.25 3 13.2426 3 12V5.25",
                },
            },
            Shape::Copy => rsx! {
                path {
                    d: "M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1",
                },
            },
            Shape::CornerDownLeft => rsx! {
                path {
                    d: "M20 4v7a4 4 0 0 1-4 4H4",
                },
            },
            Shape::CornerDownRight => rsx! {
                path {
                    d: "M4 4v7a4 4 0 0 0 4 4h12",
                },
            },
            Shape::CornerLeftDown => rsx! {
                path {
                    d: "M20 4h-7a4 4 0 0 0-4 4v12",
                },
            },
            Shape::CornerLeftUp => rsx! {
                path {
                    d: "M20 20h-7a4 4 0 0 1-4-4V4",
                },
            },
            Shape::CornerRightDown => rsx! {
                path {
                    d: "M4 4h7a4 4 0 0 1 4 4v12",
                },
            },
            Shape::CornerRightUp => rsx! {
                path {
                    d: "M4 20h7a4 4 0 0 0 4-4V4",
                },
            },
            Shape::CornerUpLeft => rsx! {
                path {
                    d: "M20 20v-7a4 4 0 0 0-4-4H4",
                },
            },
            Shape::CornerUpRight => rsx! {
                path {
                    d: "M4 20v-7a4 4 0 0 1 4-4h12",
                },
            },
            Shape::CpuChip => rsx! {
                path {
                    d: "M8.25 3V4.5M4.5 8.25H3M21 8.25H19.5M4.5 12H3M21 12H19.5M4.5 15.75H3M21 15.75H19.5M8.25 19.5V21M12 3V4.5M12 19.5V21M15.75 3V4.5M15.75 19.5V21M6.75 19.5H17.25C18.4926 19.5 19.5 18.4926 19.5 17.25V6.75C19.5 5.50736 18.4926 4.5 17.25 4.5H6.75C5.50736 4.5 4.5 5.50736 4.5 6.75V17.25C4.5 18.4926 5.50736 19.5 6.75 19.5ZM7.5 7.5H16.5V16.5H7.5V7.5Z",
                },
            },
            Shape::Cpu => rsx! {
                path {
                    d: "",
                },
            },
            Shape::CreditCard => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Crop => rsx! {
                path {
                    d: "M6.13 1L6 16a2 2 0 0 0 2 2h15 M1 6.13L16 6a2 2 0 0 1 2 2v15",
                },
            },
            Shape::Crosshair => rsx! {
                path {
                    d: "",
                },
            },
            Shape::CubeTransparent => rsx! {
                path {
                    d: "M21 7.5L18.75 6.1875M21 7.5V9.75M21 7.5L18.75 8.8125M3 7.5L5.25 6.1875M3 7.5L5.25 8.8125M3 7.5V9.75M12 12.75L14.25 11.4375M12 12.75L9.75 11.4375M12 12.75V15M12 21.75L14.25 20.4375M12 21.75V19.5M12 21.75L9.75 20.4375M9.75 3.5625L12 2.25L14.25 3.5625M21 14.25V16.5L18.75 17.8125M5.25 17.8125L3 16.5V14.25",
                },
            },
            Shape::Cube => rsx! {
                path {
                    d: "M21 7.5L12 2.25L3 7.5M21 7.5L12 12.75M21 7.5V16.5L12 21.75M3 7.5L12 12.75M3 7.5V16.5L12 21.75M12 12.75V21.75",
                },
            },
            Shape::CurrencyBangladeshi => rsx! {
                path {
                    d: "M8.25 7.49997L8.66459 7.29267C9.16327 7.04333 9.75 7.40596 9.75 7.96349V10.5M9.75 10.5H15.75M9.75 10.5H8.25M9.75 10.5V15.9383C9.75 16.2921 9.91144 16.6351 10.2229 16.803C10.7518 17.0882 11.357 17.25 12 17.25C13.8142 17.25 15.3275 15.9617 15.675 14.25C15.7579 13.8414 15.412 13.5 14.995 13.5H14.25M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12Z",
                },
            },
            Shape::CurrencyDollar => rsx! {
                path {
                    d: "M12 6V18M9 15.1818L9.87887 15.841C11.0504 16.7197 12.9498 16.7197 14.1214 15.841C15.2929 14.9623 15.2929 13.5377 14.1214 12.659C13.5355 12.2196 12.7677 12 11.9999 12C11.275 12 10.5502 11.7804 9.99709 11.341C8.891 10.4623 8.891 9.03772 9.9971 8.15904C11.1032 7.28036 12.8965 7.28036 14.0026 8.15904L14.4175 8.48863M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12Z",
                },
            },
            Shape::CurrencyEuro => rsx! {
                path {
                    d: "M14.25 7.75625C12.667 7.19798 10.8341 7.5519 9.56802 8.81802C7.81066 10.5754 7.81066 13.4246 9.56802 15.182C10.8341 16.4481 12.667 16.802 14.25 16.2437M7.5 10.5H12.75M7.5 13.5H12.75M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12Z",
                },
            },
            Shape::CurrencyPound => rsx! {
                path {
                    d: "M14.1213 7.62877C12.9497 6.45719 11.0503 6.45719 9.87868 7.62877C9.37424 8.13321 9.08699 8.7726 9.01694 9.43073C8.9944 9.64251 9.01512 9.85582 9.04524 10.0667L9.5512 13.6084C9.68065 14.5146 9.5307 15.4386 9.12135 16.2573L9 16.5L10.5385 15.9872C11.0003 15.8332 11.4997 15.8332 11.9615 15.9872L12.6158 16.2053C13.182 16.394 13.7999 16.3501 14.3336 16.0832L15 15.75M8.25 12H12M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12Z",
                },
            },
            Shape::CurrencyRupee => rsx! {
                path {
                    d: "M15 8.25L9 8.25M15 11.25H9M12 17.25L9 14.25H10.5C12.1569 14.25 13.5 12.9069 13.5 11.25C13.5 9.59315 12.1569 8.25 10.5 8.25M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12Z",
                },
            },
            Shape::CurrencyYen => rsx! {
                path {
                    d: "M9 7.5L12 12M12 12L15 7.5M12 12V17.25M15 12H9M15 15H9M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12Z",
                },
            },
            Shape::CursorArrowRays => rsx! {
                path {
                    d: "M15.0423 21.6718L13.6835 16.6007M13.6835 16.6007L11.1741 18.826L11.7425 9.35623L16.9697 17.2731L13.6835 16.6007ZM12 2.25V4.5M17.8336 4.66637L16.2426 6.25736M20.25 10.5H18M7.75736 14.7426L6.16637 16.3336M6 10.5H3.75M7.75736 6.25736L6.16637 4.66637",
                },
            },
            Shape::CursorArrowRipple => rsx! {
                path {
                    d: "M15.0423 21.6718L13.6835 16.6007M13.6835 16.6007L11.1741 18.826L11.7425 9.35623L16.9697 17.2731L13.6835 16.6007ZM6.16637 16.3336C2.94454 13.1118 2.94454 7.88819 6.16637 4.66637C9.38819 1.44454 14.6118 1.44454 17.8336 4.66637C19.4445 6.27724 20.25 8.38854 20.25 10.4999M8.28769 14.2123C6.23744 12.1621 6.23744 8.83794 8.28769 6.78769C10.3379 4.73744 13.6621 4.73744 15.7123 6.78769C16.7374 7.8128 17.25 9.15637 17.25 10.4999",
                },
            },
            Shape::Database => rsx! {
                path {
                    d: "M21 12c0 1.66-4 3-9 3s-9-1.34-9-3 M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5",
                },
            },
            Shape::Delete => rsx! {
                path {
                    d: "M21 4H8l-7 8 7 8h13a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2z",
                },
            },
            Shape::DevicePhoneMobile => rsx! {
                path {
                    d: "M10.5 1.5H8.25C7.00736 1.5 6 2.50736 6 3.75V20.25C6 21.4926 7.00736 22.5 8.25 22.5H15.75C16.9926 22.5 18 21.4926 18 20.25V3.75C18 2.50736 16.9926 1.5 15.75 1.5H13.5M10.5 1.5V3H13.5V1.5M10.5 1.5H13.5M10.5 20.25H13.5",
                },
            },
            Shape::DeviceTablet => rsx! {
                path {
                    d: "M10.5 19.5H13.5M6.75 21.75H17.25C18.4926 21.75 19.5 20.7426 19.5 19.5V4.5C19.5 3.25736 18.4926 2.25 17.25 2.25H6.75C5.50736 2.25 4.5 3.25736 4.5 4.5V19.5C4.5 20.7426 5.50736 21.75 6.75 21.75Z",
                },
            },
            Shape::Disc => rsx! {
                path {
                    d: "",
                },
            },
            Shape::DivideCircle => rsx! {
                path {
                    d: "",
                },
            },
            Shape::DivideSquare => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Divide => rsx! {
                path {
                    d: "",
                },
            },
            Shape::DocumentArrowDown => rsx! {
                path {
                    d: "M19.5 14.25V11.625C19.5 9.76104 17.989 8.25 16.125 8.25H14.625C14.0037 8.25 13.5 7.74632 13.5 7.125V5.625C13.5 3.76104 11.989 2.25 10.125 2.25H8.25M9 14.25L12 17.25M12 17.25L15 14.25M12 17.25L12 11.25M10.5 2.25H5.625C5.00368 2.25 4.5 2.75368 4.5 3.375V20.625C4.5 21.2463 5.00368 21.75 5.625 21.75H18.375C18.9963 21.75 19.5 21.2463 19.5 20.625V11.25C19.5 6.27944 15.4706 2.25 10.5 2.25Z",
                },
            },
            Shape::DocumentArrowUp => rsx! {
                path {
                    d: "M19.5 14.25V11.625C19.5 9.76104 17.989 8.25 16.125 8.25H14.625C14.0037 8.25 13.5 7.74632 13.5 7.125V5.625C13.5 3.76104 11.989 2.25 10.125 2.25H8.25M15 14.25L12 11.25M12 11.25L9 14.25M12 11.25L12 17.25M10.5 2.25H5.625C5.00368 2.25 4.5 2.75368 4.5 3.375V20.625C4.5 21.2463 5.00368 21.75 5.625 21.75H18.375C18.9963 21.75 19.5 21.2463 19.5 20.625V11.25C19.5 6.27944 15.4706 2.25 10.5 2.25Z",
                },
            },
            Shape::DocumentChartBar => rsx! {
                path {
                    d: "M19.5 14.25V11.625C19.5 9.76104 17.989 8.25 16.125 8.25H14.625C14.0037 8.25 13.5 7.74632 13.5 7.125V5.625C13.5 3.76104 11.989 2.25 10.125 2.25H8.25M9 16.5V17.25M12 14.25V17.25M15 12V17.25M10.5 2.25H5.625C5.00368 2.25 4.5 2.75368 4.5 3.375V20.625C4.5 21.2463 5.00368 21.75 5.625 21.75H18.375C18.9963 21.75 19.5 21.2463 19.5 20.625V11.25C19.5 6.27944 15.4706 2.25 10.5 2.25Z",
                },
            },
            Shape::DocumentCheck => rsx! {
                path {
                    d: "M10.125 2.25H5.625C5.00368 2.25 4.5 2.75368 4.5 3.375V20.625C4.5 21.2463 5.00368 21.75 5.625 21.75H18.375C18.9963 21.75 19.5 21.2463 19.5 20.625V11.625M10.125 2.25H10.5C15.4706 2.25 19.5 6.27944 19.5 11.25V11.625M10.125 2.25C11.989 2.25 13.5 3.76104 13.5 5.625V7.125C13.5 7.74632 14.0037 8.25 14.625 8.25H16.125C17.989 8.25 19.5 9.76104 19.5 11.625M9 15L11.25 17.25L15 12",
                },
            },
            Shape::DocumentDuplicate => rsx! {
                path {
                    d: "M15.75 17.25V20.625C15.75 21.2463 15.2463 21.75 14.625 21.75H4.875C4.25368 21.75 3.75 21.2463 3.75 20.625V7.875C3.75 7.25368 4.25368 6.75 4.875 6.75H6.75C7.26107 6.75 7.76219 6.7926 8.25 6.87444M15.75 17.25H19.125C19.7463 17.25 20.25 16.7463 20.25 16.125V11.25C20.25 6.79051 17.0066 3.08855 12.75 2.37444C12.2622 2.2926 11.7611 2.25 11.25 2.25H9.375C8.75368 2.25 8.25 2.75368 8.25 3.375V6.87444M15.75 17.25H9.375C8.75368 17.25 8.25 16.7463 8.25 16.125V6.87444M20.25 13.5V11.625C20.25 9.76104 18.739 8.25 16.875 8.25H15.375C14.7537 8.25 14.25 7.74632 14.25 7.125V5.625C14.25 3.76104 12.739 2.25 10.875 2.25H9.75",
                },
            },
            Shape::DocumentMagnifyingGlass => rsx! {
                path {
                    d: "M19.5 14.25V11.625C19.5 9.76104 17.989 8.25 16.125 8.25H14.625C14.0037 8.25 13.5 7.74632 13.5 7.125V5.625C13.5 3.76104 11.989 2.25 10.125 2.25H8.25M13.4812 15.7312L15 17.25M10.5 2.25H5.625C5.00368 2.25 4.5 2.75368 4.5 3.375V19.875C4.5 20.4963 5.00368 21 5.625 21H18.375C18.9963 21 19.5 20.4963 19.5 19.875V11.25C19.5 6.27944 15.4706 2.25 10.5 2.25ZM14.25 13.875C14.25 15.3247 13.0747 16.5 11.625 16.5C10.1753 16.5 9 15.3247 9 13.875C9 12.4253 10.1753 11.25 11.625 11.25C13.0747 11.25 14.25 12.4253 14.25 13.875Z",
                },
            },
            Shape::DocumentMinus => rsx! {
                path {
                    d: "M19.5 14.25V11.625C19.5 9.76104 17.989 8.25 16.125 8.25H14.625C14.0037 8.25 13.5 7.74632 13.5 7.125V5.625C13.5 3.76104 11.989 2.25 10.125 2.25H8.25M15 14.25H9M10.5 2.25H5.625C5.00368 2.25 4.5 2.75368 4.5 3.375V20.625C4.5 21.2463 5.00368 21.75 5.625 21.75H18.375C18.9963 21.75 19.5 21.2463 19.5 20.625V11.25C19.5 6.27944 15.4706 2.25 10.5 2.25Z",
                },
            },
            Shape::DocumentPlus => rsx! {
                path {
                    d: "M19.5 14.25V11.625C19.5 9.76104 17.989 8.25 16.125 8.25H14.625C14.0037 8.25 13.5 7.74632 13.5 7.125V5.625C13.5 3.76104 11.989 2.25 10.125 2.25H8.25M12 11.25V17.25M15 14.25H9M10.5 2.25H5.625C5.00368 2.25 4.5 2.75368 4.5 3.375V20.625C4.5 21.2463 5.00368 21.75 5.625 21.75H18.375C18.9963 21.75 19.5 21.2463 19.5 20.625V11.25C19.5 6.27944 15.4706 2.25 10.5 2.25Z",
                },
            },
            Shape::DocumentText => rsx! {
                path {
                    d: "M19.5 14.25V11.625C19.5 9.76104 17.989 8.25 16.125 8.25H14.625C14.0037 8.25 13.5 7.74632 13.5 7.125V5.625C13.5 3.76104 11.989 2.25 10.125 2.25H8.25M8.25 15H15.75M8.25 18H12M10.5 2.25H5.625C5.00368 2.25 4.5 2.75368 4.5 3.375V20.625C4.5 21.2463 5.00368 21.75 5.625 21.75H18.375C18.9963 21.75 19.5 21.2463 19.5 20.625V11.25C19.5 6.27944 15.4706 2.25 10.5 2.25Z",
                },
            },
            Shape::Document => rsx! {
                path {
                    d: "M19.5 14.25V11.625C19.5 9.76104 17.989 8.25 16.125 8.25H14.625C14.0037 8.25 13.5 7.74632 13.5 7.125V5.625C13.5 3.76104 11.989 2.25 10.125 2.25H8.25M10.5 2.25H5.625C5.00368 2.25 4.5 2.75368 4.5 3.375V20.625C4.5 21.2463 5.00368 21.75 5.625 21.75H18.375C18.9963 21.75 19.5 21.2463 19.5 20.625V11.25C19.5 6.27944 15.4706 2.25 10.5 2.25Z",
                },
            },
            Shape::DollarSign => rsx! {
                path {
                    d: "M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6",
                },
            },
            Shape::DownloadCloud => rsx! {
                path {
                    d: "M20.88 18.09A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.29",
                },
            },
            Shape::Download => rsx! {
                path {
                    d: "M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4",
                },
            },
            Shape::Dribbble => rsx! {
                path {
                    d: "M8.56 2.75c4.37 6.03 6.02 9.42 8.03 17.72m2.54-15.38c-3.72 4.35-8.94 5.66-16.88 5.85m19.5 1.9c-3.5-.93-6.63-.82-8.94 0-2.58.92-5.01 2.86-7.44 6.32",
                },
            },
            Shape::Droplet => rsx! {
                path {
                    d: "M12 2.69l5.66 5.66a8 8 0 1 1-11.31 0z",
                },
            },
            Shape::Edit2 => rsx! {
                path {
                    d: "M17 3a2.828 2.828 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5L17 3z",
                },
            },
            Shape::Edit3 => rsx! {
                path {
                    d: "M12 20h9 M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z",
                },
            },
            Shape::Edit => rsx! {
                path {
                    d: "M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7 M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z",
                },
            },
            Shape::EllipsisHorizontalCircle => rsx! {
                path {
                    d: "M8.625 12C8.625 12.2071 8.45711 12.375 8.25 12.375C8.04289 12.375 7.875 12.2071 7.875 12C7.875 11.7929 8.04289 11.625 8.25 11.625C8.45711 11.625 8.625 11.7929 8.625 12ZM8.625 12H8.25M12.375 12C12.375 12.2071 12.2071 12.375 12 12.375C11.7929 12.375 11.625 12.2071 11.625 12C11.625 11.7929 11.7929 11.625 12 11.625C12.2071 11.625 12.375 11.7929 12.375 12ZM12.375 12H12M16.125 12C16.125 12.2071 15.9571 12.375 15.75 12.375C15.5429 12.375 15.375 12.2071 15.375 12C15.375 11.7929 15.5429 11.625 15.75 11.625C15.9571 11.625 16.125 11.7929 16.125 12ZM16.125 12H15.75M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12Z",
                },
            },
            Shape::EllipsisHorizontal => rsx! {
                path {
                    d: "M6.75 12C6.75 12.4142 6.41421 12.75 6 12.75C5.58579 12.75 5.25 12.4142 5.25 12C5.25 11.5858 5.58579 11.25 6 11.25C6.41421 11.25 6.75 11.5858 6.75 12Z M12.75 12C12.75 12.4142 12.4142 12.75 12 12.75C11.5858 12.75 11.25 12.4142 11.25 12C11.25 11.5858 11.5858 11.25 12 11.25C12.4142 11.25 12.75 11.5858 12.75 12Z M18.75 12C18.75 12.4142 18.4142 12.75 18 12.75C17.5858 12.75 17.25 12.4142 17.25 12C17.25 11.5858 17.5858 11.25 18 11.25C18.4142 11.25 18.75 11.5858 18.75 12Z",
                },
            },
            Shape::EllipsisVertical => rsx! {
                path {
                    d: "M12 6.75C11.5858 6.75 11.25 6.41421 11.25 6C11.25 5.58579 11.5858 5.25 12 5.25C12.4142 5.25 12.75 5.58579 12.75 6C12.75 6.41421 12.4142 6.75 12 6.75Z M12 12.75C11.5858 12.75 11.25 12.4142 11.25 12C11.25 11.5858 11.5858 11.25 12 11.25C12.4142 11.25 12.75 11.5858 12.75 12C12.75 12.4142 12.4142 12.75 12 12.75Z M12 18.75C11.5858 18.75 11.25 18.4142 11.25 18C11.25 17.5858 11.5858 17.25 12 17.25C12.4142 17.25 12.75 17.5858 12.75 18C12.75 18.4142 12.4142 18.75 12 18.75Z",
                },
            },
            Shape::EnvelopeOpen => rsx! {
                path {
                    d: "M21.75 9.00021V9.9063C21.75 10.734 21.2955 11.4949 20.5667 11.8874L14.0893 15.3752M2.25 9.00021V9.9063C2.25 10.734 2.70448 11.4949 3.43328 11.8874L9.91074 15.3752M18.75 17.8849L14.0893 15.3752M14.0893 15.3752L13.0667 14.8246C12.4008 14.466 11.5992 14.466 10.9333 14.8246L9.91074 15.3752M9.91074 15.3752L5.25 17.8849M21.75 19.5002C21.75 20.7429 20.7426 21.7502 19.5 21.7502H4.5C3.25736 21.7502 2.25 20.7429 2.25 19.5002L2.25 8.84412C2.25 8.01639 2.70448 7.25549 3.43328 6.86307L10.9333 2.8246C11.5992 2.46602 12.4008 2.46602 13.0667 2.8246L20.5667 6.86307C21.2955 7.2555 21.75 8.01639 21.75 8.84413V19.5002Z",
                },
            },
            Shape::Envelope => rsx! {
                path {
                    d: "M21.75 6.75V17.25C21.75 18.4926 20.7426 19.5 19.5 19.5H4.5C3.25736 19.5 2.25 18.4926 2.25 17.25V6.75M21.75 6.75C21.75 5.50736 20.7426 4.5 19.5 4.5H4.5C3.25736 4.5 2.25 5.50736 2.25 6.75M21.75 6.75V6.99271C21.75 7.77405 21.3447 8.49945 20.6792 8.90894L13.1792 13.5243C12.4561 13.9694 11.5439 13.9694 10.8208 13.5243L3.32078 8.90894C2.65535 8.49945 2.25 7.77405 2.25 6.99271V6.75",
                },
            },
            Shape::ExclamationCircle => rsx! {
                path {
                    d: "M12 9V12.75M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12ZM12 15.75H12.0075V15.7575H12V15.75Z",
                },
            },
            Shape::ExclamationTriangle => rsx! {
                path {
                    d: "M11.9998 9.00006V12.7501M2.69653 16.1257C1.83114 17.6257 2.91371 19.5001 4.64544 19.5001H19.3541C21.0858 19.5001 22.1684 17.6257 21.303 16.1257L13.9487 3.37819C13.0828 1.87736 10.9167 1.87736 10.0509 3.37819L2.69653 16.1257ZM11.9998 15.7501H12.0073V15.7576H11.9998V15.7501Z",
                },
            },
            Shape::ExternalLink => rsx! {
                path {
                    d: "M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6",
                },
            },
            Shape::EyeDropper => rsx! {
                path {
                    d: "M15 11.25L16.5 12.75L17.25 12V8.75798L19.5264 8.14802C20.019 8.01652 20.4847 7.75778 20.8712 7.37132C22.0428 6.19975 22.0428 4.30025 20.8712 3.12868C19.6996 1.95711 17.8001 1.95711 16.6286 3.12868C16.2421 3.51509 15.9832 3.98069 15.8517 4.47324L15.2416 6.74998H12L11.25 7.49998L12.75 8.99999M15 11.25L6.53033 19.7197C6.19077 20.0592 5.73022 20.25 5.25 20.25C4.76978 20.25 4.30924 20.4408 3.96967 20.7803L3 21.75L2.25 21L3.21967 20.0303C3.55923 19.6908 3.75 19.2302 3.75 18.75C3.75 18.2698 3.94077 17.8092 4.28033 17.4697L12.75 8.99999M15 11.25L12.75 8.99999",
                },
            },
            Shape::EyeOff => rsx! {
                path {
                    d: "M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24",
                },
            },
            Shape::EyeSlash => rsx! {
                path {
                    d: "M3.9799 8.22257C3.05679 9.31382 2.35239 10.596 1.93433 12.0015C3.22562 16.338 7.24308 19.5 11.9991 19.5C12.9916 19.5 13.952 19.3623 14.8622 19.1049M6.2276 6.22763C7.88385 5.13558 9.86768 4.5 11.9999 4.5C16.7559 4.5 20.7734 7.66205 22.0647 11.9985C21.3528 14.3919 19.8105 16.4277 17.772 17.772M6.2276 6.22763L2.99997 3M6.2276 6.22763L9.87865 9.87868M17.772 17.772L21 21M17.772 17.772L14.1213 14.1213M14.1213 14.1213C14.6642 13.5784 15 12.8284 15 12C15 10.3431 13.6568 9 12 9C11.1715 9 10.4215 9.33579 9.87865 9.87868M14.1213 14.1213L9.87865 9.87868",
                },
            },
            Shape::Eye => rsx! {
                path {
                    d: "M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z",
                },
            },
            Shape::FaceFrown => rsx! {
                path {
                    d: "M15.1823 16.3179C14.3075 15.4432 13.1623 15.0038 12.0158 14.9999C10.859 14.996 9.70095 15.4353 8.81834 16.3179M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12ZM9.75 9.75C9.75 10.1642 9.58211 10.5 9.375 10.5C9.16789 10.5 9 10.1642 9 9.75C9 9.33579 9.16789 9 9.375 9C9.58211 9 9.75 9.33579 9.75 9.75ZM9.375 9.75H9.3825V9.765H9.375V9.75ZM15 9.75C15 10.1642 14.8321 10.5 14.625 10.5C14.4179 10.5 14.25 10.1642 14.25 9.75C14.25 9.33579 14.4179 9 14.625 9C14.8321 9 15 9.33579 15 9.75ZM14.625 9.75H14.6325V9.765H14.625V9.75Z",
                },
            },
            Shape::FaceSmile => rsx! {
                path {
                    d: "M15.182 15.182C13.4246 16.9393 10.5754 16.9393 8.81802 15.182M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12ZM9.75 9.75C9.75 10.1642 9.58211 10.5 9.375 10.5C9.16789 10.5 9 10.1642 9 9.75C9 9.33579 9.16789 9 9.375 9C9.58211 9 9.75 9.33579 9.75 9.75ZM9.375 9.75H9.3825V9.765H9.375V9.75ZM15 9.75C15 10.1642 14.8321 10.5 14.625 10.5C14.4179 10.5 14.25 10.1642 14.25 9.75C14.25 9.33579 14.4179 9 14.625 9C14.8321 9 15 9.33579 15 9.75ZM14.625 9.75H14.6325V9.765H14.625V9.75Z",
                },
            },
            Shape::Facebook => rsx! {
                path {
                    d: "M18 2h-3a5 5 0 0 0-5 5v3H7v4h3v8h4v-8h3l1-4h-4V7a1 1 0 0 1 1-1h3z",
                },
            },
            Shape::FastForward => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Feather => rsx! {
                path {
                    d: "M20.24 12.24a6 6 0 0 0-8.49-8.49L5 10.5V19h8.5z",
                },
            },
            Shape::Figma => rsx! {
                path {
                    d: "M5 5.5A3.5 3.5 0 0 1 8.5 2H12v7H8.5A3.5 3.5 0 0 1 5 5.5z M12 2h3.5a3.5 3.5 0 1 1 0 7H12V2z M12 12.5a3.5 3.5 0 1 1 7 0 3.5 3.5 0 1 1-7 0z M5 19.5A3.5 3.5 0 0 1 8.5 16H12v3.5a3.5 3.5 0 1 1-7 0z M5 12.5A3.5 3.5 0 0 1 8.5 9H12v7H8.5A3.5 3.5 0 0 1 5 12.5z",
                },
            },
            Shape::FileMinus => rsx! {
                path {
                    d: "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z",
                },
            },
            Shape::FilePlus => rsx! {
                path {
                    d: "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z",
                },
            },
            Shape::FileText => rsx! {
                path {
                    d: "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z",
                },
            },
            Shape::File => rsx! {
                path {
                    d: "M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z",
                },
            },
            Shape::Film => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Filter => rsx! {
                path {
                    d: "",
                },
            },
            Shape::FingerPrint => rsx! {
                path {
                    d: "M7.86391 4.24259C9.04956 3.45731 10.4714 3 12 3C16.1421 3 19.5 6.35786 19.5 10.5C19.5 13.4194 18.9443 16.2089 17.9324 18.7685M5.7426 6.36391C4.95732 7.54956 4.5 8.97138 4.5 10.5C4.5 11.9677 4.07875 13.3369 3.3501 14.4931M5.33889 18.052C7.14811 16.0555 8.25 13.4065 8.25 10.5C8.25 8.42893 9.92893 6.75 12 6.75C14.0711 6.75 15.75 8.42893 15.75 10.5C15.75 11.0269 15.7286 11.5487 15.686 12.0646M12.0003 10.5C12.0003 14.2226 10.6443 17.6285 8.39916 20.2506M15.033 15.6543C14.4852 17.5743 13.6391 19.3685 12.5479 20.9836",
                },
            },
            Shape::Fire => rsx! {
                path {
                    d: "M15.3622 5.21385C18.2427 6.50093 20.25 9.391 20.25 12.7499C20.25 17.3062 16.5563 20.9999 12 20.9999C7.44365 20.9999 3.75 17.3062 3.75 12.7499C3.75 10.5378 4.62058 8.52914 6.03781 7.0477C6.8043 8.11811 7.82048 8.99755 9.00121 9.60089C9.04632 6.82521 10.348 4.35503 12.3621 2.73438C13.1255 3.75813 14.1379 4.61845 15.3622 5.21385Z M12 18.0003C14.0711 18.0003 15.75 16.3214 15.75 14.2503C15.75 12.347 14.3321 10.7749 12.4949 10.5327C11.4866 11.4372 10.7862 12.6781 10.5703 14.0789C9.78769 13.8876 9.06529 13.5428 8.43682 13.0782C8.31559 13.4469 8.25 13.841 8.25 14.2503C8.25 16.3214 9.92893 18.0003 12 18.0003Z",
                },
            },
            Shape::Flag => rsx! {
                path {
                    d: "M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z",
                },
            },
            Shape::FolderArrowDown => rsx! {
                path {
                    d: "M9 13.5L12 16.5M12 16.5L15 13.5M12 16.5L12 10.5M13.0607 6.31066L10.9393 4.18934C10.658 3.90804 10.2765 3.75 9.87868 3.75H4.5C3.25736 3.75 2.25 4.75736 2.25 6V18C2.25 19.2426 3.25736 20.25 4.5 20.25H19.5C20.7426 20.25 21.75 19.2426 21.75 18V9C21.75 7.75736 20.7426 6.75 19.5 6.75H14.1213C13.7235 6.75 13.342 6.59197 13.0607 6.31066Z",
                },
            },
            Shape::FolderMinus => rsx! {
                path {
                    d: "M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z",
                },
            },
            Shape::FolderOpen => rsx! {
                path {
                    d: "M3.75002 9.77602C3.86206 9.7589 3.97701 9.75 4.0943 9.75H19.9058C20.023 9.75 20.138 9.7589 20.25 9.77602M3.75002 9.77602C2.55402 9.9588 1.68986 11.0788 1.86691 12.3182L2.72405 18.3182C2.8824 19.4267 3.83173 20.25 4.95144 20.25H19.0486C20.1683 20.25 21.1176 19.4267 21.276 18.3182L22.1331 12.3182C22.3102 11.0788 21.446 9.9588 20.25 9.77602M3.75002 9.77602V6C3.75002 4.75736 4.75738 3.75 6.00002 3.75H9.8787C10.2765 3.75 10.6581 3.90804 10.9394 4.18934L13.0607 6.31066C13.342 6.59197 13.7235 6.75 14.1213 6.75H18C19.2427 6.75 20.25 7.75736 20.25 9V9.77602",
                },
            },
            Shape::FolderPlus => rsx! {
                path {
                    d: "M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z",
                },
            },
            Shape::Folder => rsx! {
                path {
                    d: "M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z",
                },
            },
            Shape::Forward => rsx! {
                path {
                    d: "M3 8.68819C3 7.82439 3.93317 7.28285 4.68316 7.71141L11.7906 11.7728C12.5464 12.2047 12.5464 13.2945 11.7906 13.7264L4.68316 17.7878C3.93317 18.2164 3 17.6748 3 16.811V8.68819Z M12.75 8.68819C12.75 7.82439 13.6832 7.28285 14.4332 7.71141L21.5406 11.7728C22.2964 12.2047 22.2964 13.2945 21.5406 13.7264L14.4332 17.7878C13.6832 18.2164 12.75 17.6748 12.75 16.811V8.68819Z",
                },
            },
            Shape::Framer => rsx! {
                path {
                    d: "M5 16V9h14V2H5l14 14h-7m-7 0l7 7v-7m-7 0h7",
                },
            },
            Shape::Frown => rsx! {
                path {
                    d: "M16 16s-1.5-2-4-2-4 2-4 2",
                },
            },
            Shape::Funnel => rsx! {
                path {
                    d: "M12.0001 3C14.7548 3 17.4552 3.23205 20.0831 3.67767C20.6159 3.76803 21 4.23355 21 4.77402V5.81802C21 6.41476 20.7629 6.98705 20.341 7.40901L14.909 12.841C14.4871 13.2629 14.25 13.8352 14.25 14.432V17.3594C14.25 18.2117 13.7685 18.9908 13.0062 19.3719L9.75 21V14.432C9.75 13.8352 9.51295 13.2629 9.09099 12.841L3.65901 7.40901C3.23705 6.98705 3 6.41476 3 5.81802V4.77404C3 4.23357 3.38408 3.76805 3.91694 3.67769C6.54479 3.23206 9.24533 3 12.0001 3Z",
                },
            },
            Shape::Gif => rsx! {
                path {
                    d: "M12.75 8.25V15.75M18.75 8.25H15.75V12M15.75 12V15.75M15.75 12H18M9.75 9.34835C8.72056 7.88388 7.05152 7.88388 6.02208 9.34835C4.99264 10.8128 4.99264 13.1872 6.02208 14.6517C7.05152 16.1161 8.72056 16.1161 9.75 14.6517V12H8.25M4.5 19.5H19.5C20.7426 19.5 21.75 18.4926 21.75 17.25V6.75C21.75 5.50736 20.7426 4.5 19.5 4.5H4.5C3.25736 4.5 2.25 5.50736 2.25 6.75V17.25C2.25 18.4926 3.25736 19.5 4.5 19.5Z",
                },
            },
            Shape::GiftTop => rsx! {
                path {
                    d: "M12 3.75V20.25M2.25 12H21.75M6.375 17.25C9.06739 17.25 11.25 15.0674 11.25 12.375V12M17.625 17.25C14.9326 17.25 12.75 15.0674 12.75 12.375V12M3.75 20.25H20.25C21.0784 20.25 21.75 19.5784 21.75 18.75V5.25C21.75 4.42157 21.0784 3.75 20.25 3.75H3.75C2.92157 3.75 2.25 4.42157 2.25 5.25V18.75C2.25 19.5784 2.92157 20.25 3.75 20.25ZM16.3713 10.8107C14.9623 12.2197 12.1286 11.8714 12.1286 11.8714C12.1286 11.8714 11.7803 9.03772 13.1893 7.62871C14.068 6.75003 15.4926 6.75003 16.3713 7.62871C17.2499 8.50739 17.2499 9.93201 16.3713 10.8107ZM10.773 7.62874C12.182 9.03775 11.8336 11.8714 11.8336 11.8714C11.8336 11.8714 9 12.2197 7.59099 10.8107C6.71231 9.93204 6.71231 8.50742 7.59099 7.62874C8.46967 6.75006 9.89429 6.75006 10.773 7.62874Z",
                },
            },
            Shape::Gift => rsx! {
                path {
                    d: "M12 7H7.5a2.5 2.5 0 0 1 0-5C11 2 12 7 12 7z M12 7h4.5a2.5 2.5 0 0 0 0-5C13 2 12 7 12 7z",
                },
            },
            Shape::GitBranch => rsx! {
                path {
                    d: "M18 9a9 9 0 0 1-9 9",
                },
            },
            Shape::GitCommit => rsx! {
                path {
                    d: "",
                },
            },
            Shape::GitMerge => rsx! {
                path {
                    d: "M6 21V9a9 9 0 0 0 9 9",
                },
            },
            Shape::GitPullRequest => rsx! {
                path {
                    d: "M13 6h3a2 2 0 0 1 2 2v7",
                },
            },
            Shape::Github => rsx! {
                path {
                    d: "M9 19c-5 1.5-5-2.5-7-3m14 6v-3.87a3.37 3.37 0 0 0-.94-2.61c3.14-.35 6.44-1.54 6.44-7A5.44 5.44 0 0 0 20 4.77 5.07 5.07 0 0 0 19.91 1S18.73.65 16 2.48a13.38 13.38 0 0 0-7 0C6.27.65 5.09 1 5.09 1A5.07 5.07 0 0 0 5 4.77a5.44 5.44 0 0 0-1.5 3.78c0 5.42 3.3 6.61 6.44 7A3.37 3.37 0 0 0 9 18.13V22",
                },
            },
            Shape::Gitlab => rsx! {
                path {
                    d: "M22.65 14.39L12 22.13 1.35 14.39a.84.84 0 0 1-.3-.94l1.22-3.78 2.44-7.51A.42.42 0 0 1 4.82 2a.43.43 0 0 1 .58 0 .42.42 0 0 1 .11.18l2.44 7.49h8.1l2.44-7.51A.42.42 0 0 1 18.6 2a.43.43 0 0 1 .58 0 .42.42 0 0 1 .11.18l2.44 7.51L23 13.45a.84.84 0 0 1-.35.94z",
                },
            },
            Shape::GlobeAlt => rsx! {
                path {
                    d: "M12 21C16.1926 21 19.7156 18.1332 20.7157 14.2529M12 21C7.80742 21 4.28442 18.1332 3.2843 14.2529M12 21C14.4853 21 16.5 16.9706 16.5 12C16.5 7.02944 14.4853 3 12 3M12 21C9.51472 21 7.5 16.9706 7.5 12C7.5 7.02944 9.51472 3 12 3M12 3C15.3652 3 18.299 4.84694 19.8431 7.58245M12 3C8.63481 3 5.70099 4.84694 4.15692 7.58245M19.8431 7.58245C17.7397 9.40039 14.9983 10.5 12 10.5C9.00172 10.5 6.26027 9.40039 4.15692 7.58245M19.8431 7.58245C20.5797 8.88743 21 10.3946 21 12C21 12.778 20.9013 13.5329 20.7157 14.2529M20.7157 14.2529C18.1334 15.6847 15.1619 16.5 12 16.5C8.8381 16.5 5.86662 15.6847 3.2843 14.2529M3.2843 14.2529C3.09871 13.5329 3 12.778 3 12C3 10.3946 3.42032 8.88743 4.15692 7.58245",
                },
            },
            Shape::GlobeAmericas => rsx! {
                path {
                    d: "M6.11507 5.19043L6.4339 7.10337C6.63948 8.33689 7.22535 9.47535 8.10962 10.3596L9.75 12L9.36262 12.7747C9.14607 13.2079 9.23096 13.731 9.57336 14.0734L10.9205 15.4205C11.1315 15.6315 11.25 15.9176 11.25 16.216V17.3047C11.25 17.7308 11.4908 18.1204 11.8719 18.3109L12.0247 18.3874C12.4579 18.6039 12.981 18.519 13.3234 18.1766L14.0461 17.4539C15.161 16.339 15.952 14.9419 16.3344 13.4122C16.4357 13.0073 16.2962 12.5802 15.9756 12.313L14.6463 11.2053C14.3947 10.9956 14.0642 10.906 13.7411 10.9598L12.5711 11.1548C12.2127 11.2146 11.8475 11.0975 11.5906 10.8406L11.2955 10.5455C10.8562 10.1062 10.8562 9.39384 11.2955 8.9545L11.4266 8.82336C11.769 8.48095 12.2921 8.39607 12.7253 8.61263L13.3292 8.91459C13.4415 8.97076 13.5654 9 13.691 9C14.2924 9 14.6835 8.3671 14.4146 7.82918L14.25 7.5L15.5057 6.66289C16.1573 6.22849 16.6842 5.63157 17.0344 4.93112L17.1803 4.63942M6.11507 5.19043C4.20716 6.84073 3 9.27939 3 12C3 16.9706 7.02944 21 12 21C16.9706 21 21 16.9706 21 12C21 8.95801 19.4908 6.26851 17.1803 4.63942M6.11507 5.19043C7.69292 3.82562 9.75004 3 12 3C13.9286 3 15.7155 3.6066 17.1803 4.63942",
                },
            },
            Shape::GlobeAsiaAustralia => rsx! {
                path {
                    d: "M12.75 3.03081V3.59808C12.75 3.93196 12.8983 4.24858 13.1548 4.46233L14.2234 5.35284C14.6651 5.7209 14.7582 6.36275 14.4393 6.84112L13.9282 7.60766C13.6507 8.02398 13.2423 8.3359 12.7676 8.49413L12.6254 8.54154C11.9327 8.77243 11.6492 9.59877 12.0542 10.2063C12.4237 10.7605 12.2238 11.5131 11.6281 11.811L9 13.125L9.42339 14.1835C9.608 14.645 9.40803 15.171 8.96343 15.3933C8.5503 15.5999 8.04855 15.4814 7.77142 15.1119L7.09217 14.2062C6.59039 13.5372 5.55995 13.6301 5.18594 14.3781L4.5 15.75L3.88804 15.903M12.75 3.03081C12.5027 3.0104 12.2526 3 12 3C7.02944 3 3 7.02944 3 12C3 13.3984 3.31894 14.7223 3.88804 15.903M12.75 3.03081C17.3696 3.41192 21 7.282 21 12C21 13.8792 20.4241 15.6239 19.4391 17.0672M19.4391 17.0672L19.2628 16.5385C18.9566 15.6197 18.0968 15 17.1283 15H16.5L16.1756 14.6756C15.9031 14.4031 15.5335 14.25 15.1481 14.25C14.5977 14.25 14.0945 14.561 13.8484 15.0533L13.8119 15.1263C13.6131 15.5237 13.2567 15.8195 12.8295 15.9416L11.8408 16.2241C11.2906 16.3813 10.9461 16.9263 11.0401 17.4907L11.1131 17.9285C11.1921 18.4026 11.6022 18.75 12.0828 18.75C12.9291 18.75 13.6805 19.2916 13.9482 20.0945L14.1628 20.7384M19.4391 17.0672C18.2095 18.8688 16.3425 20.2007 14.1628 20.7384M14.1628 20.7384C13.47 20.9093 12.7456 21 12 21C8.42785 21 5.34177 18.9189 3.88804 15.903M15.7498 9C15.7498 9.89602 15.3569 10.7003 14.7341 11.25",
                },
            },
            Shape::GlobeEuropeAfrica => rsx! {
                path {
                    d: "M20.8929 13.3929L19.7582 12.2582C19.5872 12.0872 19.4449 11.8897 19.3367 11.6734L18.2567 9.5133C18.1304 9.26078 17.7938 9.20616 17.5942 9.4058C17.3818 9.61824 17.0708 9.69881 16.782 9.61627L15.5091 9.25259C15.0257 9.11447 14.5239 9.40424 14.402 9.892C14.3108 10.2566 14.4587 10.6392 14.7715 10.8476L15.3582 11.2388C15.9489 11.6326 16.0316 12.4684 15.5297 12.9703L15.3295 13.1705C15.1185 13.3815 15 13.6676 15 13.966V14.3768C15 14.7846 14.8892 15.1847 14.6794 15.5344L13.3647 17.7254C12.9834 18.3611 12.2964 18.75 11.5552 18.75C10.9724 18.75 10.5 18.2776 10.5 17.6948V16.5233C10.5 15.6033 9.93986 14.7759 9.08563 14.4343L8.43149 14.1726C7.44975 13.7799 6.8739 12.7566 7.04773 11.7136L7.05477 11.6714C7.10117 11.393 7.19956 11.1257 7.3448 10.8837L7.43421 10.7347C7.92343 9.91928 8.87241 9.49948 9.80483 9.68597L10.9827 9.92153C11.5574 10.0365 12.124 9.69096 12.285 9.12744L12.4935 8.39774C12.6422 7.87721 12.3991 7.32456 11.9149 7.08245L11.25 6.75L11.159 6.84099C10.7371 7.26295 10.1648 7.5 9.56802 7.5H9.38709C9.13924 7.5 8.90095 7.59905 8.7257 7.7743C8.44222 8.05778 8.00814 8.12907 7.64958 7.94979C7.16433 7.70716 6.98833 7.10278 7.26746 6.63757L8.67936 4.2844C8.82024 4.04961 8.91649 3.79207 8.96453 3.52474M20.8929 13.3929C20.9634 12.9389 21 12.4737 21 12C21 7.02944 16.9706 3 12 3C10.9348 3 9.91287 3.18504 8.96453 3.52474M20.8929 13.3929C20.2234 17.702 16.4968 21 12 21C7.02944 21 3 16.9706 3 12C3 8.09461 5.48749 4.77021 8.96453 3.52474",
                },
            },
            Shape::Globe => rsx! {
                path {
                    d: "M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z",
                },
            },
            Shape::Grid => rsx! {
                path {
                    d: "",
                },
            },
            Shape::HandRaised => rsx! {
                path {
                    d: "M10.05 4.575C10.05 3.70515 9.34486 3 8.47501 3C7.60516 3 6.90001 3.70515 6.90001 4.575L6.9 7.575M10.05 4.575L10.05 3.075C10.05 2.20515 10.7552 1.5 11.625 1.5C12.4949 1.5 13.2 2.20515 13.2 3.075L13.2 4.575M10.05 4.575L10.125 10.5M13.2 11.25V4.575M13.2 4.575C13.2 3.70515 13.9052 3 14.775 3C15.6449 3 16.35 3.70515 16.35 4.575V15M6.9 7.575C6.9 6.70515 6.19485 6 5.325 6C4.45515 6 3.75 6.70515 3.75 7.575V15.75C3.75 19.4779 6.77208 22.5 10.5 22.5H12.5179C13.9103 22.5 15.2456 21.9469 16.2302 20.9623L17.9623 19.2302C18.9469 18.2456 19.5 16.9103 19.5 15.5179L19.5031 13.494C19.5046 13.3209 19.5701 13.1533 19.7007 13.0227C20.3158 12.4076 20.3158 11.4104 19.7007 10.7953C19.0857 10.1802 18.0884 10.1802 17.4733 10.7953C16.7315 11.5371 16.3578 12.5111 16.3531 13.4815M6.9 7.575V12M13.17 16.318C13.5599 15.9281 14.0035 15.6248 14.477 15.4079C15.0701 15.1362 15.71 15.0003 16.35 15M16.3519 15H16.35",
                },
            },
            Shape::HandThumbDown => rsx! {
                path {
                    d: "M7.5 15L9.75 15M17.7745 5.25C17.7851 5.30001 17.802 5.34962 17.8258 5.3978C18.4175 6.59708 18.75 7.94722 18.75 9.375C18.75 10.8618 18.3895 12.2643 17.7511 13.5M17.7745 5.25C17.6975 4.88534 17.9575 4.5 18.3493 4.5L19.2571 4.5C20.1458 4.5 20.9701 5.01802 21.2294 5.86805C21.5679 6.97738 21.75 8.15493 21.75 9.375C21.75 10.9275 21.4552 12.4111 20.9185 13.7729C20.6135 14.547 19.8327 15 19.0006 15H17.9479C17.476 15 17.2027 14.4441 17.4477 14.0407C17.5548 13.8644 17.6561 13.684 17.7511 13.5M17.7745 5.25L16.4803 5.25C15.9966 5.25 15.5161 5.17203 15.0572 5.01908L11.9428 3.98093C11.4839 3.82798 11.0034 3.75 10.5198 3.75L6.50377 3.75C5.88581 3.75 5.2866 3.99749 4.899 4.47878C3.24188 6.53642 2.25 9.15238 2.25 12C2.25 12.4341 2.27306 12.8629 2.31801 13.2851C2.4267 14.306 3.34564 15 4.37227 15L7.49809 15C8.11638 15 8.48896 15.724 8.22337 16.2823C7.75956 17.2574 7.5 18.3484 7.5 19.5C7.5 20.7426 8.50736 21.75 9.75 21.75C10.1642 21.75 10.5 21.4142 10.5 21V20.3666C10.5 19.7941 10.6092 19.2269 10.8219 18.6954C11.1257 17.9357 11.7523 17.3644 12.4745 16.9798C13.5883 16.3866 14.5627 15.5662 15.3359 14.5803C15.8335 13.9458 16.5611 13.5 17.3674 13.5H17.7511",
                },
            },
            Shape::HandThumbUp => rsx! {
                path {
                    d: "M6.63257 10.5C7.43892 10.5 8.16648 10.0542 8.6641 9.41967C9.43726 8.43384 10.4117 7.6134 11.5255 7.02021C12.2477 6.63563 12.8743 6.06428 13.1781 5.30464C13.3908 4.7731 13.5 4.20587 13.5 3.63338V3C13.5 2.58579 13.8358 2.25 14.25 2.25C15.4926 2.25 16.5 3.25736 16.5 4.5C16.5 5.65163 16.2404 6.74263 15.7766 7.71771C15.511 8.27604 15.8836 9 16.5019 9H19.6277C20.6544 9 21.5733 9.69399 21.682 10.7149C21.7269 11.1371 21.75 11.5658 21.75 12C21.75 14.8476 20.7581 17.4636 19.101 19.5212C18.7134 20.0025 18.1142 20.25 17.4962 20.25H13.4802C12.9966 20.25 12.5161 20.172 12.0572 20.0191L8.94278 18.9809C8.48393 18.828 8.00342 18.75 7.51975 18.75H5.90421M14.25 9H16.5M5.90421 18.75C5.98702 18.9546 6.07713 19.1554 6.17423 19.3522C6.37137 19.7517 6.0962 20.25 5.65067 20.25H4.74289C3.85418 20.25 3.02991 19.732 2.77056 18.882C2.43208 17.7726 2.25 16.5951 2.25 15.375C2.25 13.8225 2.54481 12.3389 3.08149 10.9771C3.38655 10.203 4.16733 9.75 4.99936 9.75H6.05212C6.52404 9.75 6.7973 10.3059 6.5523 10.7093C5.72588 12.0698 5.25 13.6668 5.25 15.375C5.25 16.5685 5.48232 17.7078 5.90421 18.75Z",
                },
            },
            Shape::HardDrive => rsx! {
                path {
                    d: "M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z",
                },
            },
            Shape::Hash => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Hashtag => rsx! {
                path {
                    d: "M5.25 8.25H20.25M3.75 15.75H18.75M16.95 2.25L13.05 21.75M10.9503 2.25L7.05029 21.75",
                },
            },
            Shape::Headphones => rsx! {
                path {
                    d: "M3 18v-6a9 9 0 0 1 18 0v6 M21 19a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3zM3 19a2 2 0 0 0 2 2h1a2 2 0 0 0 2-2v-3a2 2 0 0 0-2-2H3z",
                },
            },
            Shape::Heart => rsx! {
                path {
                    d: "M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z",
                },
            },
            Shape::HelpCircle => rsx! {
                path {
                    d: "M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3",
                },
            },
            Shape::Hexagon => rsx! {
                path {
                    d: "M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z",
                },
            },
            Shape::HomeModern => rsx! {
                path {
                    d: "M8.25 21V16.125C8.25 15.5037 8.75368 15 9.375 15H11.625C12.2463 15 12.75 15.5037 12.75 16.125V21M12.75 21H17.25V3.54545M12.75 21H20.25V10.75M2.25 21H3.75M21.75 21H3.75M2.25 9L6.75 7.36364M18.75 3L17.25 3.54545M17.25 9.75L20.25 10.75M21.75 11.25L20.25 10.75M6.75 7.36364V3H3.75V21M6.75 7.36364L17.25 3.54545",
                },
            },
            Shape::Home => rsx! {
                path {
                    d: "M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z",
                },
            },
            Shape::Identification => rsx! {
                path {
                    d: "M15 9H18.75M15 12H18.75M15 15H18.75M4.5 19.5H19.5C20.7426 19.5 21.75 18.4926 21.75 17.25V6.75C21.75 5.50736 20.7426 4.5 19.5 4.5H4.5C3.25736 4.5 2.25 5.50736 2.25 6.75V17.25C2.25 18.4926 3.25736 19.5 4.5 19.5ZM10.5 9.375C10.5 10.4105 9.66053 11.25 8.625 11.25C7.58947 11.25 6.75 10.4105 6.75 9.375C6.75 8.33947 7.58947 7.5 8.625 7.5C9.66053 7.5 10.5 8.33947 10.5 9.375ZM11.7939 15.7114C10.8489 16.2147 9.77021 16.5 8.62484 16.5C7.47948 16.5 6.40074 16.2147 5.45581 15.7114C5.92986 14.4207 7.16983 13.5 8.62484 13.5C10.0799 13.5 11.3198 14.4207 11.7939 15.7114Z",
                },
            },
            Shape::Image => rsx! {
                path {
                    d: "",
                },
            },
            Shape::InboxArrowDown => rsx! {
                path {
                    d: "M9 3.75H6.91179C5.92403 3.75 5.05178 4.39423 4.76129 5.33831L2.3495 13.1766C2.28354 13.391 2.25 13.614 2.25 13.8383V18C2.25 19.2426 3.25736 20.25 4.5 20.25H19.5C20.7426 20.25 21.75 19.2426 21.75 18V13.8383C21.75 13.614 21.7165 13.391 21.6505 13.1766L19.2387 5.33831C18.9482 4.39423 18.076 3.75 17.0882 3.75H15M2.25 13.5H6.10942C6.96166 13.5 7.74075 13.9815 8.12188 14.7438L8.37812 15.2562C8.75925 16.0185 9.53834 16.5 10.3906 16.5H13.6094C14.4617 16.5 15.2408 16.0185 15.6219 15.2562L15.8781 14.7438C16.2592 13.9815 17.0383 13.5 17.8906 13.5H21.75M12 3V11.25M12 11.25L9 8.25M12 11.25L15 8.25",
                },
            },
            Shape::InboxStack => rsx! {
                path {
                    d: "M7.875 14.25L9.08906 16.1925C9.50022 16.8504 10.2213 17.25 10.9971 17.25H13.0029C13.7787 17.25 14.4998 16.8504 14.9109 16.1925L16.125 14.25M2.40961 9H7.04584C7.79813 9 8.50065 9.37598 8.91795 10.0019L9.08205 10.2481C9.49935 10.874 10.2019 11.25 10.9542 11.25H13.0458C13.7981 11.25 14.5007 10.874 14.9179 10.2481L15.0821 10.0019C15.4993 9.37598 16.2019 9 16.9542 9H21.5904M2.40961 9C2.30498 9.2628 2.25 9.54503 2.25 9.83233V12C2.25 13.2426 3.25736 14.25 4.5 14.25H19.5C20.7426 14.25 21.75 13.2426 21.75 12V9.83233C21.75 9.54503 21.695 9.2628 21.5904 9M2.40961 9C2.50059 8.77151 2.62911 8.55771 2.79167 8.36805L6.07653 4.53572C6.50399 4.03702 7.12802 3.75 7.78485 3.75H16.2151C16.872 3.75 17.496 4.03702 17.9235 4.53572L21.2083 8.36805C21.3709 8.55771 21.4994 8.77151 21.5904 9M4.5 20.25H19.5C20.7426 20.25 21.75 19.2426 21.75 18V15.375C21.75 14.7537 21.2463 14.25 20.625 14.25H3.375C2.75368 14.25 2.25 14.7537 2.25 15.375V18C2.25 19.2426 3.25736 20.25 4.5 20.25Z",
                },
            },
            Shape::Inbox => rsx! {
                path {
                    d: "M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z",
                },
            },
            Shape::Info => rsx! {
                path {
                    d: "",
                },
            },
            Shape::InformationCircle => rsx! {
                path {
                    d: "M11.25 11.25L11.2915 11.2293C11.8646 10.9427 12.5099 11.4603 12.3545 12.082L11.6455 14.918C11.4901 15.5397 12.1354 16.0573 12.7085 15.7707L12.75 15.75M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12ZM12 8.25H12.0075V8.2575H12V8.25Z",
                },
            },
            Shape::Instagram => rsx! {
                path {
                    d: "M16 11.37A4 4 0 1 1 12.63 8 4 4 0 0 1 16 11.37z",
                },
            },
            Shape::Italic => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Key => rsx! {
                path {
                    d: "M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4",
                },
            },
            Shape::Language => rsx! {
                path {
                    d: "M10.5 21L15.75 9.75L21 21M12 18H19.5M3 5.62136C4.96557 5.37626 6.96804 5.25 9 5.25M9 5.25C10.1208 5.25 11.2326 5.28841 12.3343 5.364M9 5.25V3M12.3343 5.364C11.1763 10.6578 7.68868 15.0801 3 17.5023M12.3343 5.364C13.2298 5.42545 14.1186 5.51146 15 5.62136M10.4113 14.1162C8.78554 12.4619 7.47704 10.4949 6.58432 8.31366",
                },
            },
            Shape::Layers => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Layout => rsx! {
                path {
                    d: "",
                },
            },
            Shape::LifeBuoy => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Lifebuoy => rsx! {
                path {
                    d: "M16.7124 4.3299C17.2999 4.69153 17.8548 5.12691 18.364 5.63604C18.8731 6.14517 19.3085 6.70012 19.6701 7.28763M16.7124 4.3299L13.2636 8.46838M16.7124 4.3299C13.8316 2.5567 10.1684 2.5567 7.28763 4.3299M19.6701 7.28763L15.5316 10.7364M19.6701 7.28763C21.4433 10.1684 21.4433 13.8316 19.6701 16.7124M15.5316 10.7364C15.3507 10.2297 15.0574 9.75408 14.6517 9.34835C14.2459 8.94262 13.7703 8.6493 13.2636 8.46838M15.5316 10.7364C15.8228 11.5519 15.8228 12.4481 15.5316 13.2636M13.2636 8.46838C12.4481 8.17721 11.5519 8.17721 10.7364 8.46838M15.5316 13.2636C15.3507 13.7703 15.0574 14.2459 14.6517 14.6517C14.2459 15.0574 13.7703 15.3507 13.2636 15.5316M15.5316 13.2636L19.6701 16.7124M19.6701 16.7124C19.3085 17.2999 18.8731 17.8548 18.364 18.364C17.8548 18.8731 17.2999 19.3085 16.7124 19.6701M16.7124 19.6701L13.2636 15.5316M16.7124 19.6701C13.8316 21.4433 10.1684 21.4433 7.28763 19.6701M13.2636 15.5316C12.4481 15.8228 11.5519 15.8228 10.7364 15.5316M10.7364 15.5316C10.2297 15.3507 9.75408 15.0574 9.34835 14.6517C8.94262 14.2459 8.6493 13.7703 8.46838 13.2636M10.7364 15.5316L7.28763 19.6701M7.28763 19.6701C6.70012 19.3085 6.14517 18.8731 5.63604 18.364C5.12691 17.8548 4.69153 17.2999 4.3299 16.7124M4.3299 16.7124L8.46838 13.2636M4.3299 16.7124C2.5567 13.8316 2.5567 10.1684 4.3299 7.28763M8.46838 13.2636C8.17721 12.4481 8.17721 11.5519 8.46838 10.7364M8.46838 10.7364C8.6493 10.2297 8.94262 9.75408 9.34835 9.34835C9.75408 8.94262 10.2297 8.6493 10.7364 8.46838M8.46838 10.7364L4.3299 7.28763M10.7364 8.46838L7.28763 4.3299M7.28763 4.3299C6.70012 4.69153 6.14517 5.12691 5.63604 5.63604C5.12691 6.14517 4.69153 6.70013 4.3299 7.28763",
                },
            },
            Shape::LightBulb => rsx! {
                path {
                    d: "M12 18V12.75M12 12.75C12.5179 12.75 13.0206 12.6844 13.5 12.561M12 12.75C11.4821 12.75 10.9794 12.6844 10.5 12.561M14.25 20.0394C13.5212 20.1777 12.769 20.25 12 20.25C11.231 20.25 10.4788 20.1777 9.75 20.0394M13.5 22.422C13.007 22.4736 12.5066 22.5 12 22.5C11.4934 22.5 10.993 22.4736 10.5 22.422M14.25 18V17.8083C14.25 16.8254 14.9083 15.985 15.7585 15.4917C17.9955 14.1938 19.5 11.7726 19.5 9C19.5 4.85786 16.1421 1.5 12 1.5C7.85786 1.5 4.5 4.85786 4.5 9C4.5 11.7726 6.00446 14.1938 8.24155 15.4917C9.09173 15.985 9.75 16.8254 9.75 17.8083V18",
                },
            },
            Shape::Link2 => rsx! {
                path {
                    d: "M15 7h3a5 5 0 0 1 5 5 5 5 0 0 1-5 5h-3m-6 0H6a5 5 0 0 1-5-5 5 5 0 0 1 5-5h3",
                },
            },
            Shape::Link => rsx! {
                path {
                    d: "M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71 M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71",
                },
            },
            Shape::Linkedin => rsx! {
                path {
                    d: "M16 8a6 6 0 0 1 6 6v7h-4v-7a2 2 0 0 0-2-2 2 2 0 0 0-2 2v7h-4v-7a6 6 0 0 1 6-6z",
                },
            },
            Shape::ListBullet => rsx! {
                path {
                    d: "M8.25 6.75H20.25M8.25 12H20.25M8.25 17.25H20.25M3.75 6.75H3.7575V6.7575H3.75V6.75ZM4.125 6.75C4.125 6.95711 3.95711 7.125 3.75 7.125C3.54289 7.125 3.375 6.95711 3.375 6.75C3.375 6.54289 3.54289 6.375 3.75 6.375C3.95711 6.375 4.125 6.54289 4.125 6.75ZM3.75 12H3.7575V12.0075H3.75V12ZM4.125 12C4.125 12.2071 3.95711 12.375 3.75 12.375C3.54289 12.375 3.375 12.2071 3.375 12C3.375 11.7929 3.54289 11.625 3.75 11.625C3.95711 11.625 4.125 11.7929 4.125 12ZM3.75 17.25H3.7575V17.2575H3.75V17.25ZM4.125 17.25C4.125 17.4571 3.95711 17.625 3.75 17.625C3.54289 17.625 3.375 17.4571 3.375 17.25C3.375 17.0429 3.54289 16.875 3.75 16.875C3.95711 16.875 4.125 17.0429 4.125 17.25Z",
                },
            },
            Shape::List => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Loader => rsx! {
                path {
                    d: "",
                },
            },
            Shape::LockClosed => rsx! {
                path {
                    d: "M16.5 10.5V6.75C16.5 4.26472 14.4853 2.25 12 2.25C9.51472 2.25 7.5 4.26472 7.5 6.75V10.5M6.75 21.75H17.25C18.4926 21.75 19.5 20.7426 19.5 19.5V12.75C19.5 11.5074 18.4926 10.5 17.25 10.5H6.75C5.50736 10.5 4.5 11.5074 4.5 12.75V19.5C4.5 20.7426 5.50736 21.75 6.75 21.75Z",
                },
            },
            Shape::LockOpen => rsx! {
                path {
                    d: "M13.5 10.5V6.75C13.5 4.26472 15.5147 2.25 18 2.25C20.4853 2.25 22.5 4.26472 22.5 6.75V10.5M3.75 21.75H14.25C15.4926 21.75 16.5 20.7426 16.5 19.5V12.75C16.5 11.5074 15.4926 10.5 14.25 10.5H3.75C2.50736 10.5 1.5 11.5074 1.5 12.75V19.5C1.5 20.7426 2.50736 21.75 3.75 21.75Z",
                },
            },
            Shape::Lock => rsx! {
                path {
                    d: "M7 11V7a5 5 0 0 1 10 0v4",
                },
            },
            Shape::LogIn => rsx! {
                path {
                    d: "M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4",
                },
            },
            Shape::LogOut => rsx! {
                path {
                    d: "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4",
                },
            },
            Shape::MagnifyingGlassCircle => rsx! {
                path {
                    d: "M15.75 15.75L13.2615 13.2615M13.2615 13.2615C13.8722 12.6507 14.25 11.807 14.25 10.875C14.25 9.01104 12.739 7.5 10.875 7.5C9.01104 7.5 7.5 9.01104 7.5 10.875C7.5 12.739 9.01104 14.25 10.875 14.25C11.807 14.25 12.6507 13.8722 13.2615 13.2615ZM21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12Z",
                },
            },
            Shape::MagnifyingGlassMinus => rsx! {
                path {
                    d: "M21 21L15.8033 15.8033M15.8033 15.8033C17.1605 14.4461 18 12.5711 18 10.5C18 6.35786 14.6421 3 10.5 3C6.35786 3 3 6.35786 3 10.5C3 14.6421 6.35786 18 10.5 18C12.5711 18 14.4461 17.1605 15.8033 15.8033ZM13.5 10.5H7.5",
                },
            },
            Shape::MagnifyingGlassPlus => rsx! {
                path {
                    d: "M21 21L15.8033 15.8033M15.8033 15.8033C17.1605 14.4461 18 12.5711 18 10.5C18 6.35786 14.6421 3 10.5 3C6.35786 3 3 6.35786 3 10.5C3 14.6421 6.35786 18 10.5 18C12.5711 18 14.4461 17.1605 15.8033 15.8033ZM10.5 7.5V13.5M13.5 10.5H7.5",
                },
            },
            Shape::MagnifyingGlass => rsx! {
                path {
                    d: "M21 21L15.8033 15.8033M15.8033 15.8033C17.1605 14.4461 18 12.5711 18 10.5C18 6.35786 14.6421 3 10.5 3C6.35786 3 3 6.35786 3 10.5C3 14.6421 6.35786 18 10.5 18C12.5711 18 14.4461 17.1605 15.8033 15.8033Z",
                },
            },
            Shape::Mail => rsx! {
                path {
                    d: "M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z",
                },
            },
            Shape::MapPin => rsx! {
                path {
                    d: "M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z",
                },
            },
            Shape::Map => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Maximize2 => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Maximize => rsx! {
                path {
                    d: "M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3m0 18h3a2 2 0 0 0 2-2v-3M3 16v3a2 2 0 0 0 2 2h3",
                },
            },
            Shape::Megaphone => rsx! {
                path {
                    d: "M10.3404 15.8398C9.65153 15.7803 8.95431 15.75 8.25 15.75H7.5C5.01472 15.75 3 13.7353 3 11.25C3 8.76472 5.01472 6.75 7.5 6.75H8.25C8.95431 6.75 9.65153 6.71966 10.3404 6.66022M10.3404 15.8398C10.5933 16.8015 10.9237 17.7317 11.3246 18.6234C11.5721 19.1738 11.3842 19.8328 10.8616 20.1345L10.2053 20.5134C9.6539 20.8318 8.9456 20.6306 8.67841 20.0527C8.0518 18.6973 7.56541 17.2639 7.23786 15.771M10.3404 15.8398C9.95517 14.3745 9.75 12.8362 9.75 11.25C9.75 9.66379 9.95518 8.1255 10.3404 6.66022M10.3404 15.8398C13.5 16.1124 16.4845 16.9972 19.1747 18.3749M10.3404 6.66022C13.5 6.3876 16.4845 5.50283 19.1747 4.12509M19.1747 4.12509C19.057 3.74595 18.9302 3.37083 18.7944 3M19.1747 4.12509C19.7097 5.84827 20.0557 7.65462 20.1886 9.51991M19.1747 18.3749C19.057 18.7541 18.9302 19.1292 18.7944 19.5M19.1747 18.3749C19.7097 16.6517 20.0557 14.8454 20.1886 12.9801M20.1886 9.51991C20.6844 9.93264 21 10.5545 21 11.25C21 11.9455 20.6844 12.5674 20.1886 12.9801M20.1886 9.51991C20.2293 10.0913 20.25 10.6682 20.25 11.25C20.25 11.8318 20.2293 12.4087 20.1886 12.9801",
                },
            },
            Shape::Meh => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Menu => rsx! {
                path {
                    d: "",
                },
            },
            Shape::MessageCircle => rsx! {
                path {
                    d: "M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z",
                },
            },
            Shape::MessageSquare => rsx! {
                path {
                    d: "M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z",
                },
            },
            Shape::MicOff => rsx! {
                path {
                    d: "M9 9v3a3 3 0 0 0 5.12 2.12M15 9.34V4a3 3 0 0 0-5.94-.6 M17 16.95A7 7 0 0 1 5 12v-2m14 0v2a7 7 0 0 1-.11 1.23",
                },
            },
            Shape::Mic => rsx! {
                path {
                    d: "M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z M19 10v2a7 7 0 0 1-14 0v-2",
                },
            },
            Shape::Microphone => rsx! {
                path {
                    d: "M12 18.75C15.3137 18.75 18 16.0637 18 12.75V11.25M12 18.75C8.68629 18.75 6 16.0637 6 12.75V11.25M12 18.75V22.5M8.25 22.5H15.75M12 15.75C10.3431 15.75 9 14.4069 9 12.75V4.5C9 2.84315 10.3431 1.5 12 1.5C13.6569 1.5 15 2.84315 15 4.5V12.75C15 14.4069 13.6569 15.75 12 15.75Z",
                },
            },
            Shape::Minimize2 => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Minimize => rsx! {
                path {
                    d: "M8 3v3a2 2 0 0 1-2 2H3m18 0h-3a2 2 0 0 1-2-2V3m0 18v-3a2 2 0 0 1 2-2h3M3 16h3a2 2 0 0 1 2 2v3",
                },
            },
            Shape::MinusCircle => rsx! {
                path {
                    d: "",
                },
            },
            Shape::MinusSmall => rsx! {
                path {
                    d: "M18 12L6 12",
                },
            },
            Shape::MinusSquare => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Minus => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Monitor => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Moon => rsx! {
                path {
                    d: "M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z",
                },
            },
            Shape::MoreHorizontal => rsx! {
                path {
                    d: "",
                },
            },
            Shape::MoreVertical => rsx! {
                path {
                    d: "",
                },
            },
            Shape::MousePointer => rsx! {
                path {
                    d: "M3 3l7.07 16.97 2.51-7.39 7.39-2.51L3 3z M13 13l6 6",
                },
            },
            Shape::Move => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Music => rsx! {
                path {
                    d: "M9 18V5l12-2v13",
                },
            },
            Shape::MusicalNote => rsx! {
                path {
                    d: "M9 9L19.5 6M19.5 12.5528V16.3028C19.5 17.3074 18.834 18.1903 17.8681 18.4663L16.5481 18.8434C15.3964 19.1724 14.25 18.3077 14.25 17.1099C14.25 16.305 14.7836 15.5975 15.5576 15.3764L17.8681 14.7163C18.834 14.4403 19.5 13.5574 19.5 12.5528ZM19.5 12.5528V2.25L9 5.25V15.5528M9 15.5528V19.3028C9 20.3074 8.33405 21.1903 7.36812 21.4663L6.04814 21.8434C4.89645 22.1724 3.75 21.3077 3.75 20.1099C3.75 19.305 4.2836 18.5975 5.05757 18.3764L7.36812 17.7163C8.33405 17.4403 9 16.5574 9 15.5528Z",
                },
            },
            Shape::Navigation2 => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Navigation => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Newspaper => rsx! {
                path {
                    d: "M12 7.5H13.5M12 10.5H13.5M6 13.5H13.5M6 16.5H13.5M16.5 7.5H19.875C20.4963 7.5 21 8.00368 21 8.625V18C21 19.2426 19.9926 20.25 18.75 20.25M16.5 7.5V18C16.5 19.2426 17.5074 20.25 18.75 20.25M16.5 7.5V4.875C16.5 4.25368 15.9963 3.75 15.375 3.75H4.125C3.50368 3.75 3 4.25368 3 4.875V18C3 19.2426 4.00736 20.25 5.25 20.25H18.75M6 7.5H9V10.5H6V7.5Z",
                },
            },
            Shape::NoSymbol => rsx! {
                path {
                    d: "M18.364 18.364C21.8787 14.8492 21.8787 9.15076 18.364 5.63604C14.8492 2.12132 9.15076 2.12132 5.63604 5.63604M18.364 18.364C14.8492 21.8787 9.15076 21.8787 5.63604 18.364C2.12132 14.8492 2.12132 9.15076 5.63604 5.63604M18.364 18.364L5.63604 5.63604",
                },
            },
            Shape::Octagon => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Package => rsx! {
                path {
                    d: "M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z",
                },
            },
            Shape::PaintBrush => rsx! {
                path {
                    d: "M9.53086 16.1224C9.08517 15.0243 8.00801 14.25 6.75 14.25C5.09315 14.25 3.75 15.5931 3.75 17.25C3.75 18.4926 2.74262 19.5 1.49998 19.5C1.44928 19.5 1.39898 19.4983 1.34912 19.495C2.12648 20.8428 3.58229 21.75 5.24998 21.75C7.72821 21.75 9.73854 19.7467 9.74993 17.2711C9.74998 17.2641 9.75 17.2571 9.75 17.25C9.75 16.8512 9.67217 16.4705 9.53086 16.1224ZM9.53086 16.1224C10.7252 15.7153 11.8612 15.1705 12.9175 14.5028M7.875 14.4769C8.2823 13.2797 8.8281 12.1411 9.49724 11.0825M12.9175 14.5028C14.798 13.3141 16.4259 11.7362 17.6806 9.85406L21.5566 4.04006C21.6827 3.85093 21.75 3.6287 21.75 3.40139C21.75 2.76549 21.2345 2.25 20.5986 2.25C20.3713 2.25 20.1491 2.31729 19.9599 2.44338L14.1459 6.31937C12.2638 7.57413 10.6859 9.20204 9.49724 11.0825M12.9175 14.5028C12.2396 12.9833 11.0167 11.7604 9.49724 11.0825",
                },
            },
            Shape::PaperAirplane => rsx! {
                path {
                    d: "M5.99972 12.0005L3.2688 3.125C9.88393 5.04665 16.0276 8.07649 21.4855 12.0002C16.0276 15.924 9.884 18.9539 3.26889 20.8757L5.99972 12.0005ZM5.99972 12.0005L13.5 12.0005",
                },
            },
            Shape::PaperClip => rsx! {
                path {
                    d: "M18.375 12.739L10.682 20.432C8.92462 22.1893 6.07538 22.1893 4.31802 20.432C2.56066 18.6746 2.56066 15.8254 4.31802 14.068L15.2573 3.12868C16.4289 1.95711 18.3283 1.95711 19.4999 3.12868C20.6715 4.30025 20.6715 6.19975 19.4999 7.37132L8.55158 18.3197M8.56066 18.3107C8.55764 18.3137 8.55462 18.3167 8.55158 18.3197M14.2498 8.37865L6.43934 16.1893C5.85355 16.7751 5.85355 17.7249 6.43934 18.3107C7.02211 18.8934 7.9651 18.8964 8.55158 18.3197",
                },
            },
            Shape::Paperclip => rsx! {
                path {
                    d: "M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48",
                },
            },
            Shape::PauseCircle => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Pause => rsx! {
                path {
                    d: "",
                },
            },
            Shape::PenTool => rsx! {
                path {
                    d: "M12 19l7-7 3 3-7 7-3-3z M18 13l-1.5-7.5L2 2l3.5 14.5L13 18l5-5z M2 2l7.586 7.586",
                },
            },
            Shape::PencilSquare => rsx! {
                path {
                    d: "M16.8617 4.48667L18.5492 2.79917C19.2814 2.06694 20.4686 2.06694 21.2008 2.79917C21.9331 3.53141 21.9331 4.71859 21.2008 5.45083L10.5822 16.0695C10.0535 16.5981 9.40144 16.9868 8.68489 17.2002L6 18L6.79978 15.3151C7.01323 14.5986 7.40185 13.9465 7.93052 13.4178L16.8617 4.48667ZM16.8617 4.48667L19.5 7.12499M18 14V18.75C18 19.9926 16.9926 21 15.75 21H5.25C4.00736 21 3 19.9926 3 18.75V8.24999C3 7.00735 4.00736 5.99999 5.25 5.99999H10",
                },
            },
            Shape::Pencil => rsx! {
                path {
                    d: "M16.8617 4.48667L18.5492 2.79917C19.2814 2.06694 20.4686 2.06694 21.2008 2.79917C21.9331 3.53141 21.9331 4.71859 21.2008 5.45083L6.83218 19.8195C6.30351 20.3481 5.65144 20.7368 4.93489 20.9502L2.25 21.75L3.04978 19.0651C3.26323 18.3486 3.65185 17.6965 4.18052 17.1678L16.8617 4.48667ZM16.8617 4.48667L19.5 7.12499",
                },
            },
            Shape::Percent => rsx! {
                path {
                    d: "",
                },
            },
            Shape::PhoneArrowDownLeft => rsx! {
                path {
                    d: "M14.25 9.75V5.25M14.25 9.75L18.75 9.75M14.25 9.75L20.25 3.75M17.25 21.75C8.96573 21.75 2.25 15.0343 2.25 6.75V4.5C2.25 3.25736 3.25736 2.25 4.5 2.25H5.87163C6.38785 2.25 6.83783 2.60133 6.96304 3.10215L8.06883 7.52533C8.17861 7.96445 8.01453 8.4266 7.65242 8.69818L6.3588 9.6684C5.98336 9.94998 5.81734 10.437 5.97876 10.8777C7.19015 14.1846 9.81539 16.8098 13.1223 18.0212C13.563 18.1827 14.05 18.0166 14.3316 17.6412L15.3018 16.3476C15.5734 15.9855 16.0355 15.8214 16.4747 15.9312L20.8979 17.037C21.3987 17.1622 21.75 17.6121 21.75 18.1284V19.5C21.75 20.7426 20.7426 21.75 19.5 21.75H17.25Z",
                },
            },
            Shape::PhoneArrowUpRight => rsx! {
                path {
                    d: "M20.25 3.75V8.25M20.25 3.75H15.75M20.25 3.75L14.25 9.75M17.25 21.75C8.96573 21.75 2.25 15.0343 2.25 6.75V4.5C2.25 3.25736 3.25736 2.25 4.5 2.25H5.87163C6.38785 2.25 6.83783 2.60133 6.96304 3.10215L8.06883 7.52533C8.17861 7.96445 8.01453 8.4266 7.65242 8.69818L6.3588 9.6684C5.98336 9.94998 5.81734 10.437 5.97876 10.8777C7.19015 14.1846 9.81539 16.8098 13.1223 18.0212C13.563 18.1827 14.05 18.0166 14.3316 17.6412L15.3018 16.3476C15.5734 15.9855 16.0355 15.8214 16.4747 15.9312L20.8979 17.037C21.3987 17.1622 21.75 17.6121 21.75 18.1284V19.5C21.75 20.7426 20.7426 21.75 19.5 21.75H17.25Z",
                },
            },
            Shape::PhoneCall => rsx! {
                path {
                    d: "M15.05 5A5 5 0 0 1 19 8.95M15.05 1A9 9 0 0 1 23 8.94m-1 7.98v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z",
                },
            },
            Shape::PhoneForwarded => rsx! {
                path {
                    d: "M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z",
                },
            },
            Shape::PhoneIncoming => rsx! {
                path {
                    d: "M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z",
                },
            },
            Shape::PhoneMissed => rsx! {
                path {
                    d: "M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z",
                },
            },
            Shape::PhoneOff => rsx! {
                path {
                    d: "M10.68 13.31a16 16 0 0 0 3.41 2.6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7 2 2 0 0 1 1.72 2v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.42 19.42 0 0 1-3.33-2.67m-2.67-3.34a19.79 19.79 0 0 1-3.07-8.63A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91",
                },
            },
            Shape::PhoneOutgoing => rsx! {
                path {
                    d: "M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z",
                },
            },
            Shape::PhoneXMark => rsx! {
                path {
                    d: "M15.75 3.75L18 6M18 6L20.25 8.25M18 6L20.25 3.75M18 6L15.75 8.25M17.25 21.75C8.96573 21.75 2.25 15.0343 2.25 6.75V4.5C2.25 3.25736 3.25736 2.25 4.5 2.25H5.87163C6.38785 2.25 6.83783 2.60133 6.96304 3.10215L8.06883 7.52533C8.17861 7.96445 8.01453 8.4266 7.65242 8.69818L6.3588 9.6684C5.98336 9.94998 5.81734 10.437 5.97876 10.8777C7.19015 14.1846 9.81539 16.8098 13.1223 18.0212C13.563 18.1827 14.05 18.0166 14.3316 17.6412L15.3018 16.3476C15.5734 15.9855 16.0355 15.8214 16.4747 15.9312L20.8979 17.037C21.3987 17.1622 21.75 17.6121 21.75 18.1284V19.5C21.75 20.7426 20.7426 21.75 19.5 21.75H17.25Z",
                },
            },
            Shape::Phone => rsx! {
                path {
                    d: "M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z",
                },
            },
            Shape::Photo => rsx! {
                path {
                    d: "M2.25 15.75L7.40901 10.591C8.28769 9.71231 9.71231 9.71231 10.591 10.591L15.75 15.75M14.25 14.25L15.659 12.841C16.5377 11.9623 17.9623 11.9623 18.841 12.841L21.75 15.75M3.75 19.5H20.25C21.0784 19.5 21.75 18.8284 21.75 18V6C21.75 5.17157 21.0784 4.5 20.25 4.5H3.75C2.92157 4.5 2.25 5.17157 2.25 6V18C2.25 18.8284 2.92157 19.5 3.75 19.5ZM14.25 8.25H14.2575V8.2575H14.25V8.25ZM14.625 8.25C14.625 8.45711 14.4571 8.625 14.25 8.625C14.0429 8.625 13.875 8.45711 13.875 8.25C13.875 8.04289 14.0429 7.875 14.25 7.875C14.4571 7.875 14.625 8.04289 14.625 8.25Z",
                },
            },
            Shape::PieChart => rsx! {
                path {
                    d: "M21.21 15.89A10 10 0 1 1 8 2.83 M22 12A10 10 0 0 0 12 2v10z",
                },
            },
            Shape::PlayCircle => rsx! {
                path {
                    d: "",
                },
            },
            Shape::PlayPause => rsx! {
                path {
                    d: "M21 7.5L21 18M15 7.5V18M3 16.8114V8.68858C3 7.82478 3.93317 7.28324 4.68316 7.7118L11.7906 11.7732C12.5464 12.2051 12.5464 13.2949 11.7906 13.7268L4.68316 17.7882C3.93317 18.2168 3 17.6752 3 16.8114Z",
                },
            },
            Shape::Play => rsx! {
                path {
                    d: "",
                },
            },
            Shape::PlusCircle => rsx! {
                path {
                    d: "",
                },
            },
            Shape::PlusSmall => rsx! {
                path {
                    d: "M12 6V18M18 12L6 12",
                },
            },
            Shape::PlusSquare => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Plus => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Pocket => rsx! {
                path {
                    d: "M4 3h16a2 2 0 0 1 2 2v6a10 10 0 0 1-10 10A10 10 0 0 1 2 11V5a2 2 0 0 1 2-2z",
                },
            },
            Shape::Power => rsx! {
                path {
                    d: "M18.36 6.64a9 9 0 1 1-12.73 0",
                },
            },
            Shape::PresentationChartBar => rsx! {
                path {
                    d: "M3.75 3V14.25C3.75 15.4926 4.75736 16.5 6 16.5H8.25M3.75 3H2.25M3.75 3H20.25M20.25 3H21.75M20.25 3V14.25C20.25 15.4926 19.2426 16.5 18 16.5H15.75M8.25 16.5H15.75M8.25 16.5L7.25 19.5M15.75 16.5L16.75 19.5M16.75 19.5L17.25 21M16.75 19.5H7.25M7.25 19.5L6.75 21M9 11.25V12.75M12 9V12.75M15 6.75V12.75",
                },
            },
            Shape::PresentationChartLine => rsx! {
                path {
                    d: "M3.75 3V14.25C3.75 15.4926 4.75736 16.5 6 16.5H8.25M3.75 3H2.25M3.75 3H20.25M20.25 3H21.75M20.25 3V14.25C20.25 15.4926 19.2426 16.5 18 16.5H15.75M8.25 16.5H15.75M8.25 16.5L7.25 19.5M15.75 16.5L16.75 19.5M16.75 19.5L17.25 21M16.75 19.5H7.25M7.25 19.5L6.75 21M7.5 12L10.5 9L12.6476 11.1476C13.6542 9.70301 14.9704 8.49023 16.5 7.60539",
                },
            },
            Shape::Printer => rsx! {
                path {
                    d: "M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2",
                },
            },
            Shape::PuzzlePiece => rsx! {
                path {
                    d: "M14.25 6.08694C14.25 5.73178 14.4361 5.41076 14.6512 5.1282C14.8721 4.8381 15 4.494 15 4.125C15 3.08947 13.9926 2.25 12.75 2.25C11.5074 2.25 10.5 3.08947 10.5 4.125C10.5 4.494 10.6279 4.8381 10.8488 5.1282C11.064 5.41076 11.25 5.73178 11.25 6.08694V6.08694C11.25 6.44822 10.9542 6.73997 10.593 6.72957C9.18939 6.68914 7.80084 6.58845 6.42989 6.43C6.61626 8.04276 6.72269 9.67987 6.74511 11.3373C6.75007 11.7032 6.45293 12 6.08694 12V12C5.73178 12 5.41076 11.814 5.1282 11.5988C4.8381 11.3779 4.494 11.25 4.125 11.25C3.08947 11.25 2.25 12.2574 2.25 13.5C2.25 14.7426 3.08947 15.75 4.125 15.75C4.494 15.75 4.8381 15.6221 5.1282 15.4012C5.41076 15.186 5.73178 15 6.08694 15V15C6.39613 15 6.64157 15.2608 6.6189 15.5691C6.49306 17.2812 6.27742 18.9682 5.97668 20.6256C7.49458 20.8157 9.03451 20.9348 10.5931 20.9797C10.9542 20.9901 11.2501 20.6983 11.2501 20.337V20.337C11.2501 19.9818 11.0641 19.6608 10.8489 19.3782C10.628 19.0881 10.5001 18.744 10.5001 18.375C10.5001 17.3395 11.5075 16.5 12.7501 16.5C13.9928 16.5 15.0001 17.3395 15.0001 18.375C15.0001 18.744 14.8722 19.0881 14.6513 19.3782C14.4362 19.6608 14.2501 19.9818 14.2501 20.337V20.337C14.2501 20.6699 14.5281 20.9357 14.8605 20.9161C16.6992 20.8081 18.5102 20.5965 20.2876 20.2872C20.5571 18.7389 20.7523 17.1652 20.8696 15.5698C20.8923 15.2611 20.6466 15 20.3371 15V15C19.9819 15 19.6609 15.1861 19.3783 15.4013C19.0882 15.6221 18.7441 15.75 18.3751 15.75C17.3396 15.75 16.5001 14.7427 16.5001 13.5C16.5001 12.2574 17.3396 11.25 18.3751 11.25C18.7441 11.25 19.0882 11.378 19.3783 11.5988C19.6609 11.814 19.9819 12 20.3371 12V12C20.7034 12 21.0008 11.703 20.9959 11.3367C20.9713 9.52413 20.8463 7.73572 20.6261 5.97698C18.7403 6.31916 16.816 6.55115 14.8603 6.66605C14.528 6.68557 14.25 6.41979 14.25 6.08694V6.08694Z",
                },
            },
            Shape::QrCode => rsx! {
                path {
                    d: "M3.75 4.875C3.75 4.25368 4.25368 3.75 4.875 3.75H9.375C9.99632 3.75 10.5 4.25368 10.5 4.875V9.375C10.5 9.99632 9.99632 10.5 9.375 10.5H4.875C4.25368 10.5 3.75 9.99632 3.75 9.375V4.875Z M3.75 14.625C3.75 14.0037 4.25368 13.5 4.875 13.5H9.375C9.99632 13.5 10.5 14.0037 10.5 14.625V19.125C10.5 19.7463 9.99632 20.25 9.375 20.25H4.875C4.25368 20.25 3.75 19.7463 3.75 19.125V14.625Z M13.5 4.875C13.5 4.25368 14.0037 3.75 14.625 3.75H19.125C19.7463 3.75 20.25 4.25368 20.25 4.875V9.375C20.25 9.99632 19.7463 10.5 19.125 10.5H14.625C14.0037 10.5 13.5 9.99632 13.5 9.375V4.875Z M6.75 6.75H7.5V7.5H6.75V6.75Z M6.75 16.5H7.5V17.25H6.75V16.5Z M16.5 6.75H17.25V7.5H16.5V6.75Z M13.5 13.5H14.25V14.25H13.5V13.5Z M13.5 19.5H14.25V20.25H13.5V19.5Z M19.5 13.5H20.25V14.25H19.5V13.5Z M19.5 19.5H20.25V20.25H19.5V19.5Z M16.5 16.5H17.25V17.25H16.5V16.5Z",
                },
            },
            Shape::QuestionMarkCircle => rsx! {
                path {
                    d: "M9.87891 7.51884C11.0505 6.49372 12.95 6.49372 14.1215 7.51884C15.2931 8.54397 15.2931 10.206 14.1215 11.2312C13.9176 11.4096 13.6917 11.5569 13.4513 11.6733C12.7056 12.0341 12.0002 12.6716 12.0002 13.5V14.25M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C16.9706 3 21 7.02944 21 12ZM12 17.25H12.0075V17.2575H12V17.25Z",
                },
            },
            Shape::QueueList => rsx! {
                path {
                    d: "M3.75 12H20.25M3.75 15.75H20.25M3.75 19.5H20.25M5.625 4.5H18.375C19.4105 4.5 20.25 5.33947 20.25 6.375C20.25 7.41053 19.4105 8.25 18.375 8.25H5.625C4.58947 8.25 3.75 7.41053 3.75 6.375C3.75 5.33947 4.58947 4.5 5.625 4.5Z",
                },
            },
            Shape::Radio => rsx! {
                path {
                    d: "M16.24 7.76a6 6 0 0 1 0 8.49m-8.48-.01a6 6 0 0 1 0-8.49m11.31-2.82a10 10 0 0 1 0 14.14m-14.14 0a10 10 0 0 1 0-14.14",
                },
            },
            Shape::ReceiptPercent => rsx! {
                path {
                    d: "M9 14.25L15 8.25M19.5 4.75699V21.75L15.75 20.25L12 21.75L8.25 20.25L4.5 21.75V4.75699C4.5 3.649 5.30608 2.70014 6.40668 2.57241C8.24156 2.35947 10.108 2.25 12 2.25C13.892 2.25 15.7584 2.35947 17.5933 2.57241C18.6939 2.70014 19.5 3.649 19.5 4.75699ZM9.75 9H9.7575V9.0075H9.75V9ZM10.125 9C10.125 9.20711 9.95711 9.375 9.75 9.375C9.54289 9.375 9.375 9.20711 9.375 9C9.375 8.79289 9.54289 8.625 9.75 8.625C9.95711 8.625 10.125 8.79289 10.125 9ZM14.25 13.5H14.2575V13.5075H14.25V13.5ZM14.625 13.5C14.625 13.7071 14.4571 13.875 14.25 13.875C14.0429 13.875 13.875 13.7071 13.875 13.5C13.875 13.2929 14.0429 13.125 14.25 13.125C14.4571 13.125 14.625 13.2929 14.625 13.5Z",
                },
            },
            Shape::ReceiptRefund => rsx! {
                path {
                    d: "M8.25 9.75H13.125C14.5747 9.75 15.75 10.9253 15.75 12.375C15.75 13.8247 14.5747 15 13.125 15H12M8.25 9.75L10.5 7.5M8.25 9.75L10.5 12M19.5 4.75699V21.75L15.75 20.25L12 21.75L8.25 20.25L4.5 21.75V4.75699C4.5 3.649 5.30608 2.70014 6.40668 2.57241C8.24156 2.35947 10.108 2.25 12 2.25C13.892 2.25 15.7584 2.35947 17.5933 2.57241C18.6939 2.70014 19.5 3.649 19.5 4.75699Z",
                },
            },
            Shape::RectangleGroup => rsx! {
                path {
                    d: "M2.25 7.125C2.25 6.50368 2.75368 6 3.375 6H9.375C9.99632 6 10.5 6.50368 10.5 7.125V10.875C10.5 11.4963 9.99632 12 9.375 12H3.375C2.75368 12 2.25 11.4963 2.25 10.875V7.125Z M14.25 8.625C14.25 8.00368 14.7537 7.5 15.375 7.5H20.625C21.2463 7.5 21.75 8.00368 21.75 8.625V16.875C21.75 17.4963 21.2463 18 20.625 18H15.375C14.7537 18 14.25 17.4963 14.25 16.875V8.625Z M3.75 16.125C3.75 15.5037 4.25368 15 4.875 15H10.125C10.7463 15 11.25 15.5037 11.25 16.125V18.375C11.25 18.9963 10.7463 19.5 10.125 19.5H4.875C4.25368 19.5 3.75 18.9963 3.75 18.375V16.125Z",
                },
            },
            Shape::RectangleStack => rsx! {
                path {
                    d: "M6 6.87803V6C6 4.75736 7.00736 3.75 8.25 3.75H15.75C16.9926 3.75 18 4.75736 18 6V6.87803M6 6.87803C6.23458 6.79512 6.48702 6.75 6.75 6.75H17.25C17.513 6.75 17.7654 6.79512 18 6.87803M6 6.87803C5.12611 7.18691 4.5 8.02034 4.5 9V9.87803M18 6.87803C18.8739 7.18691 19.5 8.02034 19.5 9V9.87803M19.5 9.87803C19.2654 9.79512 19.013 9.75 18.75 9.75H5.25C4.98702 9.75 4.73458 9.79512 4.5 9.87803M19.5 9.87803C20.3739 10.1869 21 11.0203 21 12V18C21 19.2426 19.9926 20.25 18.75 20.25H5.25C4.00736 20.25 3 19.2426 3 18V12C3 11.0203 3.62611 10.1869 4.5 9.87803",
                },
            },
            Shape::RefreshCcw => rsx! {
                path {
                    d: "M20.49 9A9 9 0 0 0 5.64 5.64L1 10m22 4l-4.64 4.36A9 9 0 0 1 3.51 15",
                },
            },
            Shape::RefreshCw => rsx! {
                path {
                    d: "M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15",
                },
            },
            Shape::Repeat => rsx! {
                path {
                    d: "M3 11V9a4 4 0 0 1 4-4h14 M21 13v2a4 4 0 0 1-4 4H3",
                },
            },
            Shape::ReplayOne => rsx! {
                path {
                    d: " M 15 22.74 L 12 19.74 L 15 16.74 M 6.44 5.13 C 4.94 5.63 4.71 7.62 4.64 8.57 C 4.46 11.01 4.46 13.46 4.64 15.89 C 4.71 16.85 5.12 17.75 5.8 18.43 C 6.48 19.11 7.38 19.52 8.34 19.59 C 8.56 19.61 8.78 19.62 9 19.64 M 12 19.73 C 13.23 19.73 14.45 19.68 15.66 19.59 C 16.62 19.52 17.52 19.11 18.2 18.43 C 18.88 17.75 19.29 16.85 19.36 15.89 C 19.54 13.45 19.54 11 19.36 8.57 C 19.29 7.61 18.88 6.71 18.2 6.03 C 17.52 5.35 16.62 4.94 15.66 4.87 L 10.62 4.87 M 8.44 7.62 L 8.44 1.26 L 6.42 3.15 M 10.49 7.76 L 6.53 7.76",
                },
            },
            Shape::Rewind => rsx! {
                path {
                    d: "",
                },
            },
            Shape::RocketLaunch => rsx! {
                path {
                    d: "M15.5904 14.3696C15.6948 14.8128 15.75 15.275 15.75 15.75C15.75 19.0637 13.0637 21.75 9.75 21.75V16.9503M15.5904 14.3696C19.3244 11.6411 21.75 7.22874 21.75 2.25C16.7715 2.25021 12.3595 4.67586 9.63122 8.40975M15.5904 14.3696C13.8819 15.6181 11.8994 16.514 9.75 16.9503M9.63122 8.40975C9.18777 8.30528 8.72534 8.25 8.25 8.25C4.93629 8.25 2.25 10.9363 2.25 14.25H7.05072M9.63122 8.40975C8.38285 10.1183 7.48701 12.1007 7.05072 14.25M9.75 16.9503C9.64659 16.9713 9.54279 16.9912 9.43862 17.0101C8.53171 16.291 7.70991 15.4692 6.99079 14.5623C7.00969 14.4578 7.02967 14.3537 7.05072 14.25M4.81191 16.6408C3.71213 17.4612 3 18.7724 3 20.25C3 20.4869 3.0183 20.7195 3.05356 20.9464C3.28054 20.9817 3.51313 21 3.75 21C5.22758 21 6.53883 20.2879 7.35925 19.1881M16.5 9C16.5 9.82843 15.8284 10.5 15 10.5C14.1716 10.5 13.5 9.82843 13.5 9C13.5 8.17157 14.1716 7.5 15 7.5C15.8284 7.5 16.5 8.17157 16.5 9Z",
                },
            },
            Shape::RotateCcw => rsx! {
                path {
                    d: "M3.51 15a9 9 0 1 0 2.13-9.36L1 10",
                },
            },
            Shape::RotateCw => rsx! {
                path {
                    d: "M20.49 15a9 9 0 1 1-2.12-9.36L23 10",
                },
            },
            Shape::Rss => rsx! {
                path {
                    d: "M4 11a9 9 0 0 1 9 9 M4 4a16 16 0 0 1 16 16",
                },
            },
            Shape::Save => rsx! {
                path {
                    d: "M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z",
                },
            },
            Shape::Scale => rsx! {
                path {
                    d: "M12 3V20.25M12 20.25C10.528 20.25 9.1179 20.515 7.81483 21M12 20.25C13.472 20.25 14.8821 20.515 16.1852 21M18.75 4.97089C16.5446 4.66051 14.291 4.5 12 4.5C9.70897 4.5 7.45542 4.66051 5.25 4.97089M18.75 4.97089C19.7604 5.1131 20.7608 5.28677 21.75 5.49087M18.75 4.97089L21.3704 15.6961C21.4922 16.1948 21.2642 16.7237 20.7811 16.8975C20.1468 17.1257 19.4629 17.25 18.75 17.25C18.0371 17.25 17.3532 17.1257 16.7189 16.8975C16.2358 16.7237 16.0078 16.1948 16.1296 15.6961L18.75 4.97089ZM2.25 5.49087C3.23922 5.28677 4.23956 5.1131 5.25 4.97089M5.25 4.97089L7.87036 15.6961C7.9922 16.1948 7.76419 16.7237 7.28114 16.8975C6.6468 17.1257 5.96292 17.25 5.25 17.25C4.53708 17.25 3.8532 17.1257 3.21886 16.8975C2.73581 16.7237 2.5078 16.1948 2.62964 15.6961L5.25 4.97089Z",
                },
            },
            Shape::Scissors => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Search => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Send => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ServerStack => rsx! {
                path {
                    d: "M5.25 14.25H18.75M5.25 14.25C3.59315 14.25 2.25 12.9069 2.25 11.25M5.25 14.25C3.59315 14.25 2.25 15.5931 2.25 17.25C2.25 18.9069 3.59315 20.25 5.25 20.25H18.75C20.4069 20.25 21.75 18.9069 21.75 17.25C21.75 15.5931 20.4069 14.25 18.75 14.25M2.25 11.25C2.25 9.59315 3.59315 8.25 5.25 8.25H18.75C20.4069 8.25 21.75 9.59315 21.75 11.25M2.25 11.25C2.25 10.2763 2.5658 9.32893 3.15 8.55L5.7375 5.1C6.37488 4.25016 7.37519 3.75 8.4375 3.75H15.5625C16.6248 3.75 17.6251 4.25016 18.2625 5.1L20.85 8.55C21.4342 9.32893 21.75 10.2763 21.75 11.25M21.75 11.25C21.75 12.9069 20.4069 14.25 18.75 14.25M18.75 17.25H18.7575V17.2575H18.75V17.25ZM18.75 11.25H18.7575V11.2575H18.75V11.25ZM15.75 17.25H15.7575V17.2575H15.75V17.25ZM15.75 11.25H15.7575V11.2575H15.75V11.25Z",
                },
            },
            Shape::Server => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Settings => rsx! {
                path {
                    d: "M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z",
                },
            },
            Shape::Share2 => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Share => rsx! {
                path {
                    d: "M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8",
                },
            },
            Shape::ShieldCheck => rsx! {
                path {
                    d: "M9 12.7498L11.25 14.9998L15 9.74985M12 2.71411C9.8495 4.75073 6.94563 5.99986 3.75 5.99986C3.69922 5.99986 3.64852 5.99955 3.59789 5.99892C3.2099 7.17903 3 8.43995 3 9.74991C3 15.3414 6.82432 20.0397 12 21.3719C17.1757 20.0397 21 15.3414 21 9.74991C21 8.43995 20.7901 7.17903 20.4021 5.99892C20.3515 5.99955 20.3008 5.99986 20.25 5.99986C17.0544 5.99986 14.1505 4.75073 12 2.71411Z",
                },
            },
            Shape::ShieldExclamation => rsx! {
                path {
                    d: "M12 9.00009V12.7501M12 2.71436C9.8495 4.75098 6.94563 6.00011 3.75 6.00011C3.69922 6.00011 3.64852 5.99979 3.59789 5.99916C3.2099 7.17927 3 8.4402 3 9.75015C3 15.3417 6.82432 20.04 12 21.3721C17.1757 20.04 21 15.3417 21 9.75015C21 8.4402 20.7901 7.17927 20.4021 5.99916C20.3515 5.99979 20.3008 6.00011 20.25 6.00011C17.0544 6.00011 14.1505 4.75098 12 2.71436ZM12 15.7501H12.0075V15.7576H12V15.7501Z",
                },
            },
            Shape::ShieldOff => rsx! {
                path {
                    d: "M19.69 14a6.9 6.9 0 0 0 .31-2V5l-8-3-3.16 1.18 M4.73 4.73L4 5v7c0 6 8 10 8 10a20.29 20.29 0 0 0 5.62-4.38",
                },
            },
            Shape::Shield => rsx! {
                path {
                    d: "M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z",
                },
            },
            Shape::ShoppingBag => rsx! {
                path {
                    d: "M6 2L3 6v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V6l-3-4z M16 10a4 4 0 0 1-8 0",
                },
            },
            Shape::ShoppingCart => rsx! {
                path {
                    d: "M1 1h4l2.68 13.39a2 2 0 0 0 2 1.61h9.72a2 2 0 0 0 2-1.61L23 6H6",
                },
            },
            Shape::Shuffle => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Sidebar => rsx! {
                path {
                    d: "",
                },
            },
            Shape::SignalSlash => rsx! {
                path {
                    d: "M3 3L11.7348 11.7348M11.7348 11.7348C11.8027 11.667 11.8964 11.625 12 11.625C12.2071 11.625 12.375 11.7929 12.375 12C12.375 12.1036 12.333 12.1973 12.2652 12.2652M11.7348 11.7348L12.2652 12.2652M12.2652 12.2652L21 21M14.6517 9.34835C16.1161 10.8128 16.1161 13.1872 14.6517 14.6516M16.773 7.22703C19.409 9.86307 19.409 14.1369 16.773 16.773M18.8943 5.10571C22.7019 8.91332 22.7019 15.0867 18.8943 18.8943M9.34835 14.6516C8.75129 14.0546 8.39765 13.3063 8.28743 12.5301M7.22703 16.773C5.35299 14.8989 4.81126 12.1971 5.60184 9.84448M5.10571 18.8943C2.03824 15.8268 1.44197 11.2239 3.3169 7.55955M12 12H12.0075V12.0075H12V12Z",
                },
            },
            Shape::Signal => rsx! {
                path {
                    d: "M9.34835 14.6514C7.88388 13.1869 7.88388 10.8126 9.34835 9.34811M14.6517 9.34811C16.1161 10.8126 16.1161 13.1869 14.6517 14.6514M7.22703 16.7727C4.59099 14.1367 4.59099 9.86283 7.22703 7.22679M16.773 7.22679C19.409 9.86283 19.409 14.1367 16.773 16.7727M5.10571 18.8941C1.2981 15.0864 1.2981 8.91308 5.10571 5.10547M18.8943 5.10547C22.7019 8.91308 22.7019 15.0864 18.8943 18.8941M12 11.9998H12.0075V12.0073H12V11.9998ZM12.375 11.9998C12.375 12.2069 12.2071 12.3748 12 12.3748C11.7929 12.3748 11.625 12.2069 11.625 11.9998C11.625 11.7927 11.7929 11.6248 12 11.6248C12.2071 11.6248 12.375 11.7927 12.375 11.9998Z",
                },
            },
            Shape::SkipBack => rsx! {
                path {
                    d: "",
                },
            },
            Shape::SkipForward => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Slack => rsx! {
                path {
                    d: "M14.5 10c-.83 0-1.5-.67-1.5-1.5v-5c0-.83.67-1.5 1.5-1.5s1.5.67 1.5 1.5v5c0 .83-.67 1.5-1.5 1.5z M20.5 10H19V8.5c0-.83.67-1.5 1.5-1.5s1.5.67 1.5 1.5-.67 1.5-1.5 1.5z M9.5 14c.83 0 1.5.67 1.5 1.5v5c0 .83-.67 1.5-1.5 1.5S8 21.33 8 20.5v-5c0-.83.67-1.5 1.5-1.5z M3.5 14H5v1.5c0 .83-.67 1.5-1.5 1.5S2 16.33 2 15.5 2.67 14 3.5 14z M14 14.5c0-.83.67-1.5 1.5-1.5h5c.83 0 1.5.67 1.5 1.5s-.67 1.5-1.5 1.5h-5c-.83 0-1.5-.67-1.5-1.5z M15.5 19H14v1.5c0 .83.67 1.5 1.5 1.5s1.5-.67 1.5-1.5-.67-1.5-1.5-1.5z M10 9.5C10 8.67 9.33 8 8.5 8h-5C2.67 8 2 8.67 2 9.5S2.67 11 3.5 11h5c.83 0 1.5-.67 1.5-1.5z M8.5 5H10V3.5C10 2.67 9.33 2 8.5 2S7 2.67 7 3.5 7.67 5 8.5 5z",
                },
            },
            Shape::Slash => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Sliders => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Smartphone => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Smile => rsx! {
                path {
                    d: "M8 14s1.5 2 4 2 4-2 4-2",
                },
            },
            Shape::Sparkles => rsx! {
                path {
                    d: "M9.8132 15.9038L9 18.75L8.1868 15.9038C7.75968 14.4089 6.59112 13.2403 5.09619 12.8132L2.25 12L5.09619 11.1868C6.59113 10.7597 7.75968 9.59112 8.1868 8.09619L9 5.25L9.8132 8.09619C10.2403 9.59113 11.4089 10.7597 12.9038 11.1868L15.75 12L12.9038 12.8132C11.4089 13.2403 10.2403 14.4089 9.8132 15.9038Z M18.2589 8.71454L18 9.75L17.7411 8.71454C17.4388 7.50533 16.4947 6.56117 15.2855 6.25887L14.25 6L15.2855 5.74113C16.4947 5.43883 17.4388 4.49467 17.7411 3.28546L18 2.25L18.2589 3.28546C18.5612 4.49467 19.5053 5.43883 20.7145 5.74113L21.75 6L20.7145 6.25887C19.5053 6.56117 18.5612 7.50533 18.2589 8.71454Z M16.8942 20.5673L16.5 21.75L16.1058 20.5673C15.8818 19.8954 15.3546 19.3682 14.6827 19.1442L13.5 18.75L14.6827 18.3558C15.3546 18.1318 15.8818 17.6046 16.1058 16.9327L16.5 15.75L16.8942 16.9327C17.1182 17.6046 17.6454 18.1318 18.3173 18.3558L19.5 18.75L18.3173 19.1442C17.6454 19.3682 17.1182 19.8954 16.8942 20.5673Z",
                },
            },
            Shape::SpeakerWave => rsx! {
                path {
                    d: "M19.114 5.63591C22.6287 9.15063 22.6287 14.8491 19.114 18.3638M16.4626 8.28765C18.5129 10.3379 18.5129 13.662 16.4626 15.7123M6.75 8.24993L11.4697 3.53026C11.9421 3.05778 12.75 3.39241 12.75 4.06059V19.9393C12.75 20.6074 11.9421 20.9421 11.4697 20.4696L6.75 15.7499H4.50905C3.62971 15.7499 2.8059 15.2435 2.57237 14.3957C2.36224 13.6329 2.25 12.8295 2.25 11.9999C2.25 11.1703 2.36224 10.367 2.57237 9.60416C2.8059 8.7564 3.62971 8.24993 4.50905 8.24993H6.75Z",
                },
            },
            Shape::SpeakerXMark => rsx! {
                path {
                    d: "M17.25 9.75041L19.5 12.0004M19.5 12.0004L21.75 14.2504M19.5 12.0004L21.75 9.75041M19.5 12.0004L17.25 14.2504M6.75 8.25041L11.4697 3.53074C11.9421 3.05827 12.75 3.3929 12.75 4.06107V19.9398C12.75 20.6079 11.9421 20.9426 11.4697 20.4701L6.75 15.7504H4.50905C3.62971 15.7504 2.8059 15.2439 2.57237 14.3962C2.36224 13.6334 2.25 12.83 2.25 12.0004C2.25 11.1708 2.36224 10.3675 2.57237 9.60465C2.8059 8.75689 3.62971 8.25041 4.50905 8.25041H6.75Z",
                },
            },
            Shape::Speaker => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Square2Stack => rsx! {
                path {
                    d: "M16.5 8.25V6C16.5 4.75736 15.4926 3.75 14.25 3.75H6C4.75736 3.75 3.75 4.75736 3.75 6V14.25C3.75 15.4926 4.75736 16.5 6 16.5H8.25M16.5 8.25H18C19.2426 8.25 20.25 9.25736 20.25 10.5V18C20.25 19.2426 19.2426 20.25 18 20.25H10.5C9.25736 20.25 8.25 19.2426 8.25 18V16.5M16.5 8.25H10.5C9.25736 8.25 8.25 9.25736 8.25 10.5V16.5",
                },
            },
            Shape::Square3Stack3d => rsx! {
                path {
                    d: "M6.42857 9.75L2.25 12L6.42857 14.25M6.42857 9.75L12 12.75L17.5714 9.75M6.42857 9.75L2.25 7.5L12 2.25L21.75 7.5L17.5714 9.75M17.5714 9.75L21.75 12L17.5714 14.25M17.5714 14.25L21.75 16.5L12 21.75L2.25 16.5L6.42857 14.25M17.5714 14.25L12 17.25L6.42857 14.25",
                },
            },
            Shape::Square => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Squares2x2 => rsx! {
                path {
                    d: "M3.75 6C3.75 4.75736 4.75736 3.75 6 3.75H8.25C9.49264 3.75 10.5 4.75736 10.5 6V8.25C10.5 9.49264 9.49264 10.5 8.25 10.5H6C4.75736 10.5 3.75 9.49264 3.75 8.25V6Z M3.75 15.75C3.75 14.5074 4.75736 13.5 6 13.5H8.25C9.49264 13.5 10.5 14.5074 10.5 15.75V18C10.5 19.2426 9.49264 20.25 8.25 20.25H6C4.75736 20.25 3.75 19.2426 3.75 18V15.75Z M13.5 6C13.5 4.75736 14.5074 3.75 15.75 3.75H18C19.2426 3.75 20.25 4.75736 20.25 6V8.25C20.25 9.49264 19.2426 10.5 18 10.5H15.75C14.5074 10.5 13.5 9.49264 13.5 8.25V6Z M13.5 15.75C13.5 14.5074 14.5074 13.5 15.75 13.5H18C19.2426 13.5 20.25 14.5074 20.25 15.75V18C20.25 19.2426 19.2426 20.25 18 20.25H15.75C14.5074 20.25 13.5 19.2426 13.5 18V15.75Z",
                },
            },
            Shape::SquaresPlus => rsx! {
                path {
                    d: "M13.5 16.875H16.875M16.875 16.875H20.25M16.875 16.875V13.5M16.875 16.875V20.25M6 10.5H8.25C9.49264 10.5 10.5 9.49264 10.5 8.25V6C10.5 4.75736 9.49264 3.75 8.25 3.75H6C4.75736 3.75 3.75 4.75736 3.75 6V8.25C3.75 9.49264 4.75736 10.5 6 10.5ZM6 20.25H8.25C9.49264 20.25 10.5 19.2426 10.5 18V15.75C10.5 14.5074 9.49264 13.5 8.25 13.5H6C4.75736 13.5 3.75 14.5074 3.75 15.75V18C3.75 19.2426 4.75736 20.25 6 20.25ZM15.75 10.5H18C19.2426 10.5 20.25 9.49264 20.25 8.25V6C20.25 4.75736 19.2426 3.75 18 3.75H15.75C14.5074 3.75 13.5 4.75736 13.5 6V8.25C13.5 9.49264 14.5074 10.5 15.75 10.5Z",
                },
            },
            Shape::Star => rsx! {
                path {
                    d: "",
                },
            },
            Shape::StopCircle => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Stop => rsx! {
                path {
                    d: "M5.25 7.5C5.25 6.25736 6.25736 5.25 7.5 5.25H16.5C17.7426 5.25 18.75 6.25736 18.75 7.5V16.5C18.75 17.7426 17.7426 18.75 16.5 18.75H7.5C6.25736 18.75 5.25 17.7426 5.25 16.5V7.5Z",
                },
            },
            Shape::Sun => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Sunrise => rsx! {
                path {
                    d: "M17 18a5 5 0 0 0-10 0",
                },
            },
            Shape::Sunset => rsx! {
                path {
                    d: "M17 18a5 5 0 0 0-10 0",
                },
            },
            Shape::Swatch => rsx! {
                path {
                    d: "M4.09835 19.9017C5.56282 21.3661 7.93719 21.3661 9.40165 19.9017L15.8033 13.5M6.75 21C4.67893 21 3 19.3211 3 17.25V4.125C3 3.50368 3.50368 3 4.125 3H9.375C9.99632 3 10.5 3.50368 10.5 4.125V8.1967M6.75 21C8.82107 21 10.5 19.3211 10.5 17.25V8.1967M6.75 21H19.875C20.4963 21 21 20.4963 21 19.875V14.625C21 14.0037 20.4963 13.5 19.875 13.5H15.8033M10.5 8.1967L13.3791 5.31757C13.8185 4.87823 14.5308 4.87823 14.9701 5.31757L18.6824 9.02988C19.1218 9.46922 19.1218 10.1815 18.6824 10.6209L15.8033 13.5M6.75 17.25H6.7575V17.2575H6.75V17.25Z",
                },
            },
            Shape::TableCells => rsx! {
                path {
                    d: "M3.375 19.5H20.625M3.375 19.5C2.75368 19.5 2.25 18.9963 2.25 18.375M3.375 19.5H10.875C11.4963 19.5 12 18.9963 12 18.375M2.25 18.375V5.625M2.25 18.375V16.875C2.25 16.2537 2.75368 15.75 3.375 15.75M21.75 18.375V5.625M21.75 18.375C21.75 18.9963 21.2463 19.5 20.625 19.5M21.75 18.375V16.875C21.75 16.2537 21.2463 15.75 20.625 15.75M20.625 19.5H13.125C12.5037 19.5 12 18.9963 12 18.375M21.75 5.625C21.75 5.00368 21.2463 4.5 20.625 4.5H3.375C2.75368 4.5 2.25 5.00368 2.25 5.625M21.75 5.625V7.125C21.75 7.74632 21.2463 8.25 20.625 8.25M2.25 5.625V7.125C2.25 7.74632 2.75368 8.25 3.375 8.25M3.375 8.25H20.625M3.375 8.25H10.875C11.4963 8.25 12 8.75368 12 9.375M3.375 8.25C2.75368 8.25 2.25 8.75368 2.25 9.375V10.875C2.25 11.4963 2.75368 12 3.375 12M20.625 8.25H13.125C12.5037 8.25 12 8.75368 12 9.375M20.625 8.25C21.2463 8.25 21.75 8.75368 21.75 9.375V10.875C21.75 11.4963 21.2463 12 20.625 12M3.375 12H10.875M3.375 12C2.75368 12 2.25 12.5037 2.25 13.125V14.625C2.25 15.2463 2.75368 15.75 3.375 15.75M12 10.875V9.375M12 10.875C12 11.4963 11.4963 12 10.875 12M12 10.875C12 11.4963 12.5037 12 13.125 12M10.875 12C11.4963 12 12 12.5037 12 13.125M13.125 12H20.625M13.125 12C12.5037 12 12 12.5037 12 13.125M20.625 12C21.2463 12 21.75 12.5037 21.75 13.125V14.625C21.75 15.2463 21.2463 15.75 20.625 15.75M3.375 15.75H10.875M12 14.625V13.125M12 14.625C12 15.2463 11.4963 15.75 10.875 15.75M12 14.625C12 15.2463 12.5037 15.75 13.125 15.75M10.875 15.75C11.4963 15.75 12 16.2537 12 16.875M12 18.375V16.875M12 16.875C12 16.2537 12.5037 15.75 13.125 15.75M13.125 15.75H20.625",
                },
            },
            Shape::Table => rsx! {
                path {
                    d: "M9 3H5a2 2 0 0 0-2 2v4m6-6h10a2 2 0 0 1 2 2v4M9 3v18m0 0h10a2 2 0 0 0 2-2V9M9 21H5a2 2 0 0 1-2-2V9m0 0h18",
                },
            },
            Shape::Tablet => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Tag => rsx! {
                path {
                    d: "M20.59 13.41l-7.17 7.17a2 2 0 0 1-2.83 0L2 12V2h10l8.59 8.59a2 2 0 0 1 0 2.82z",
                },
            },
            Shape::Target => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Terminal => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Thermometer => rsx! {
                path {
                    d: "M14 14.76V3.5a2.5 2.5 0 0 0-5 0v11.26a4.5 4.5 0 1 0 5 0z",
                },
            },
            Shape::ThumbsDown => rsx! {
                path {
                    d: "M10 15v4a3 3 0 0 0 3 3l4-9V2H5.72a2 2 0 0 0-2 1.7l-1.38 9a2 2 0 0 0 2 2.3zm7-13h2.67A2.31 2.31 0 0 1 22 4v7a2.31 2.31 0 0 1-2.33 2H17",
                },
            },
            Shape::ThumbsUp => rsx! {
                path {
                    d: "M14 9V5a3 3 0 0 0-3-3l-4 9v11h11.28a2 2 0 0 0 2-1.7l1.38-9a2 2 0 0 0-2-2.3zM7 22H4a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2h3",
                },
            },
            Shape::Ticket => rsx! {
                path {
                    d: "M16.5 6V6.75M16.5 9.75V10.5M16.5 13.5V14.25M16.5 17.25V18M7.5 12.75H12.75M7.5 15H10.5M3.375 5.25C2.75368 5.25 2.25 5.75368 2.25 6.375V9.40135C3.1467 9.92006 3.75 10.8896 3.75 12C3.75 13.1104 3.1467 14.0799 2.25 14.5987V17.625C2.25 18.2463 2.75368 18.75 3.375 18.75H20.625C21.2463 18.75 21.75 18.2463 21.75 17.625V14.5987C20.8533 14.0799 20.25 13.1104 20.25 12C20.25 10.8896 20.8533 9.92006 21.75 9.40135V6.375C21.75 5.75368 21.2463 5.25 20.625 5.25H3.375Z",
                },
            },
            Shape::ToggleLeft => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ToggleRight => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Tool => rsx! {
                path {
                    d: "M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z",
                },
            },
            Shape::Trash2 => rsx! {
                path {
                    d: "M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2",
                },
            },
            Shape::Trash => rsx! {
                path {
                    d: "M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2",
                },
            },
            Shape::Trello => rsx! {
                path {
                    d: "",
                },
            },
            Shape::TrendingDown => rsx! {
                path {
                    d: "",
                },
            },
            Shape::TrendingUp => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Triangle => rsx! {
                path {
                    d: "M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z",
                },
            },
            Shape::Trophy => rsx! {
                path {
                    d: "M16.5003 18.75H7.50026M16.5003 18.75C18.1571 18.75 19.5003 20.0931 19.5003 21.75H4.50026C4.50026 20.0931 5.8434 18.75 7.50026 18.75M16.5003 18.75V15.375C16.5003 14.7537 15.9966 14.25 15.3753 14.25H14.5036M7.50026 18.75V15.375C7.50026 14.7537 8.00394 14.25 8.62526 14.25H9.49689M14.5036 14.25H9.49689M14.5036 14.25C13.9563 13.3038 13.6097 12.227 13.5222 11.0777M9.49689 14.25C10.0442 13.3038 10.3908 12.227 10.4783 11.0777M5.25026 4.23636C4.26796 4.3792 3.29561 4.55275 2.33423 4.75601C2.78454 7.42349 4.99518 9.49282 7.72991 9.72775M5.25026 4.23636V4.5C5.25026 6.60778 6.21636 8.48992 7.72991 9.72775M5.25026 4.23636V2.72089C7.45568 2.41051 9.70922 2.25 12.0003 2.25C14.2913 2.25 16.5448 2.41051 18.7503 2.72089V4.23636M7.72991 9.72775C8.51748 10.3719 9.45329 10.8415 10.4783 11.0777M18.7503 4.23636V4.5C18.7503 6.60778 17.7842 8.48992 16.2706 9.72775M18.7503 4.23636C19.7326 4.3792 20.7049 4.55275 21.6663 4.75601C21.216 7.42349 19.0053 9.49282 16.2706 9.72775M16.2706 9.72775C15.483 10.3719 14.5472 10.8415 13.5222 11.0777M13.5222 11.0777C13.0331 11.1904 12.5236 11.25 12.0003 11.25C11.4769 11.25 10.9675 11.1904 10.4783 11.0777",
                },
            },
            Shape::Truck => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Tv => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Twitch => rsx! {
                path {
                    d: "M21 2H3v16h5v4l4-4h5l4-4V2zM11 11V7M16 11V7",
                },
            },
            Shape::Twitter => rsx! {
                path {
                    d: "M23 3a10.9 10.9 0 0 1-3.14 1.53 4.48 4.48 0 0 0-7.86 3v1A10.66 10.66 0 0 1 3 4s-4 9 5 13a11.64 11.64 0 0 1-7 2c9 5 20 0 20-11.5a4.5 4.5 0 0 0-.08-.83A7.72 7.72 0 0 0 23 3z",
                },
            },
            Shape::Type => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Umbrella => rsx! {
                path {
                    d: "M23 12a11.05 11.05 0 0 0-22 0zm-5 7a3 3 0 0 1-6 0v-7",
                },
            },
            Shape::Underline => rsx! {
                path {
                    d: "M6 3v7a6 6 0 0 0 6 6 6 6 0 0 0 6-6V3",
                },
            },
            Shape::Unlock => rsx! {
                path {
                    d: "M7 11V7a5 5 0 0 1 9.9-1",
                },
            },
            Shape::UploadCloud => rsx! {
                path {
                    d: "M20.39 18.39A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.3",
                },
            },
            Shape::Upload => rsx! {
                path {
                    d: "M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4",
                },
            },
            Shape::UserBlock => rsx! {
                path {
                    d: "M 15.295 6.05 C 15.295 6.48 15.205 6.91 15.045 7.31 C 14.875 7.71 14.635 8.07 14.335 8.38 C 14.025 8.69 13.665 8.93 13.265 9.09 C 12.865 9.26 12.435 9.34 12.005 9.34 C 11.575 9.34 11.145 9.25 10.745 9.09 C 10.345 8.92 9.985 8.68 9.675 8.38 C 9.365 8.07 9.125 7.71 8.965 7.31 C 8.795 6.91 8.715 6.48 8.715 6.05 C 8.715 5.18 9.065 4.34 9.685 3.72 C 10.305 3.1 11.145 2.75 12.015 2.75 C 12.885 2.75 13.725 3.1 14.345 3.72 C 14.965 4.34 15.315 5.18 15.315 6.05 L 15.315 6.05 L 15.295 6.05 Z  M 16.575 19.44 C 15.125 20.03 13.575 20.34 12.005 20.34 C 9.725 20.34 7.595 19.71 5.775 18.62 L 5.775 18.62 C 5.775 18.62 5.775 18.51 5.775 18.51 C 5.775 16.86 6.435 15.27 7.595 14.11 C 8.225 13.48 8.975 13 9.785 12.69 M 12.395 12.3 C 13.905 12.4 15.325 13.04 16.395 14.11 C 17.465 15.18 18.105 16.6 18.205 18.1 M 19.715 19.72 C 21.765 17.67 22.915 14.9 22.915 12 C 22.915 9.1 21.765 6.33 19.715 4.28 C 17.665 2.23 14.895 1.08 11.995 1.08 C 9.095 1.08 6.325 2.23 4.285 4.28 M 19.725 19.72 C 17.675 21.77 14.905 22.92 12.005 22.92 C 9.105 22.92 6.335 21.77 4.285 19.72 C 2.235 17.67 1.085 14.9 1.085 12 C 1.085 9.1 2.235 6.32 4.285 4.28 M 19.725 19.72 L 4.285 4.28",
                },
            },
            Shape::UserBlocked => rsx! {
                path {
                    d: " M 15.295 6.05 C 15.295 6.48 15.205 6.91 15.045 7.31 C 14.875 7.71 14.635 8.07 14.335 8.38 C 14.025 8.69 13.665 8.93 13.265 9.09 C 12.865 9.26 12.435 9.34 12.005 9.34 C 11.575 9.34 11.145 9.25 10.745 9.09 C 10.345 8.92 9.985 8.68 9.675 8.38 C 9.365 8.07 9.125 7.71 8.965 7.31 C 8.795 6.91 8.715 6.48 8.715 6.05 C 8.715 5.18 9.065 4.34 9.685 3.72 C 10.305 3.1 11.145 2.75 12.015 2.75 C 12.885 2.75 13.725 3.1 14.345 3.72 C 14.965 4.34 15.315 5.18 15.315 6.05 L 15.315 6.05 L 15.295 6.05 Z  M 16.575 19.44 C 15.125 20.03 13.575 20.34 12.005 20.34 C 9.725 20.34 7.595 19.71 5.775 18.62 L 5.775 18.62 C 5.775 18.62 5.775 18.51 5.775 18.51 C 5.775 16.86 6.435 15.27 7.595 14.11 C 8.225 13.48 8.975 13 9.785 12.69 M 12.395 12.3 C 13.905 12.4 15.325 13.04 16.395 14.11 C 17.465 15.18 18.105 16.6 18.205 18.1 M 19.715 19.72 C 21.765 17.67 22.915 14.9 22.915 12 C 22.915 9.1 21.765 6.33 19.715 4.28 C 17.665 2.23 14.895 1.08 11.995 1.08 C 9.095 1.08 6.325 2.23 4.285 4.28 M 19.725 19.72 C 17.675 21.77 14.905 22.92 12.005 22.92 C 9.105 22.92 6.335 21.77 4.285 19.72 C 2.235 17.67 1.085 14.9 1.085 12 C 1.085 9.1 2.235 6.32 4.285 4.28 M 19.725 19.72 L 4.285 4.28",
                },
            },
            Shape::UserCheck => rsx! {
                path {
                    d: "M16 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2",
                },
            },
            Shape::UserCircle => rsx! {
                path {
                    d: "M17.9815 18.7248C16.6121 16.9175 14.4424 15.75 12 15.75C9.55761 15.75 7.38789 16.9175 6.01846 18.7248M17.9815 18.7248C19.8335 17.0763 21 14.6744 21 12C21 7.02944 16.9706 3 12 3C7.02944 3 3 7.02944 3 12C3 14.6744 4.1665 17.0763 6.01846 18.7248M17.9815 18.7248C16.3915 20.1401 14.2962 21 12 21C9.70383 21 7.60851 20.1401 6.01846 18.7248M15 9.75C15 11.4069 13.6569 12.75 12 12.75C10.3431 12.75 9 11.4069 9 9.75C9 8.09315 10.3431 6.75 12 6.75C13.6569 6.75 15 8.09315 15 9.75Z",
                },
            },
            Shape::UserGroup => rsx! {
                path {
                    d: "M17.9999 18.7191C18.2474 18.7396 18.4978 18.75 18.7506 18.75C19.7989 18.75 20.8054 18.5708 21.741 18.2413C21.7473 18.1617 21.7506 18.0812 21.7506 18C21.7506 16.3431 20.4074 15 18.7506 15C18.123 15 17.5403 15.1927 17.0587 15.5222M17.9999 18.7191C18 18.7294 18 18.7397 18 18.75C18 18.975 17.9876 19.1971 17.9635 19.4156C16.2067 20.4237 14.1707 21 12 21C9.82933 21 7.79327 20.4237 6.03651 19.4156C6.01238 19.1971 6 18.975 6 18.75C6 18.7397 6.00003 18.7295 6.00008 18.7192M17.9999 18.7191C17.994 17.5426 17.6494 16.4461 17.0587 15.5222M17.0587 15.5222C15.9928 13.8552 14.1255 12.75 12 12.75C9.87479 12.75 8.00765 13.8549 6.94169 15.5216M6.94169 15.5216C6.46023 15.1925 5.87796 15 5.25073 15C3.59388 15 2.25073 16.3431 2.25073 18C2.25073 18.0812 2.25396 18.1617 2.26029 18.2413C3.19593 18.5708 4.2024 18.75 5.25073 18.75C5.50307 18.75 5.75299 18.7396 6.00008 18.7192M6.94169 15.5216C6.35071 16.4457 6.00598 17.5424 6.00008 18.7192M15 6.75C15 8.40685 13.6569 9.75 12 9.75C10.3431 9.75 9 8.40685 9 6.75C9 5.09315 10.3431 3.75 12 3.75C13.6569 3.75 15 5.09315 15 6.75ZM21 9.75C21 10.9926 19.9926 12 18.75 12C17.5074 12 16.5 10.9926 16.5 9.75C16.5 8.50736 17.5074 7.5 18.75 7.5C19.9926 7.5 21 8.50736 21 9.75ZM7.5 9.75C7.5 10.9926 6.49264 12 5.25 12C4.00736 12 3 10.9926 3 9.75C3 8.50736 4.00736 7.5 5.25 7.5C6.49264 7.5 7.5 8.50736 7.5 9.75Z",
                },
            },
            Shape::UserMinus => rsx! {
                path {
                    d: "M16 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2",
                },
            },
            Shape::UserPlus => rsx! {
                path {
                    d: "M16 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2",
                },
            },
            Shape::UserX => rsx! {
                path {
                    d: "M16 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2",
                },
            },
            Shape::User => rsx! {
                path {
                    d: "M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2",
                },
            },
            Shape::Users => rsx! {
                path {
                    d: "M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2 M23 21v-2a4 4 0 0 0-3-3.87 M16 3.13a4 4 0 0 1 0 7.75",
                },
            },
            Shape::Variable => rsx! {
                path {
                    d: "M4.74455 3C3.61952 5.77929 3 8.8173 3 12C3 15.1827 3.61952 18.2207 4.74455 21M19.5 3C20.4673 5.77929 21 8.8173 21 12C21 15.1827 20.4673 18.2207 19.5 21M8.25 8.88462L9.6945 7.99569C10.1061 7.74241 10.6463 7.93879 10.7991 8.39726L13.2009 15.6027C13.3537 16.0612 13.8939 16.2576 14.3055 16.0043L15.75 15.1154M7.5 15.8654L7.71335 15.9556C8.45981 16.2715 9.32536 16.012 9.77495 15.3376L14.225 8.66243C14.6746 7.98804 15.5402 7.72854 16.2867 8.04435L16.5 8.13462",
                },
            },
            Shape::VideoCameraSlash => rsx! {
                path {
                    d: "M15.75 10.5L20.4697 5.78033C20.9421 5.30786 21.75 5.64248 21.75 6.31066V17.6893C21.75 18.3575 20.9421 18.6921 20.4697 18.2197L15.75 13.5M12 18.75H4.5C3.25736 18.75 2.25 17.7426 2.25 16.5V9M15.091 18.091L16.5 19.5M15.091 18.091C15.4982 17.6838 15.75 17.1213 15.75 16.5V7.5C15.75 6.25736 14.7426 5.25 13.5 5.25H4.5C3.87868 5.25 3.31618 5.50184 2.90901 5.90901M15.091 18.091L2.90901 5.90901M1.5 4.5L2.90901 5.90901",
                },
            },
            Shape::VideoCamera => rsx! {
                path {
                    d: "M15.75 10.5L20.4697 5.78033C20.9421 5.30786 21.75 5.64248 21.75 6.31066V17.6893C21.75 18.3575 20.9421 18.6921 20.4697 18.2197L15.75 13.5M4.5 18.75H13.5C14.7426 18.75 15.75 17.7426 15.75 16.5V7.5C15.75 6.25736 14.7426 5.25 13.5 5.25H4.5C3.25736 5.25 2.25 6.25736 2.25 7.5V16.5C2.25 17.7426 3.25736 18.75 4.5 18.75Z",
                },
            },
            Shape::VideoOff => rsx! {
                path {
                    d: "M16 16v1a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h2m5.66 0H14a2 2 0 0 1 2 2v3.34l1 1L23 7v10",
                },
            },
            Shape::Video => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ViewColumns => rsx! {
                path {
                    d: "M9 4.5V19.5M15 4.5V19.5M4.125 19.5H19.875C20.4963 19.5 21 18.9963 21 18.375V5.625C21 5.00368 20.4963 4.5 19.875 4.5H4.125C3.50368 4.5 3 5.00368 3 5.625V18.375C3 18.9963 3.50368 19.5 4.125 19.5Z",
                },
            },
            Shape::ViewfinderCircle => rsx! {
                path {
                    d: "M7.5 3.75H6C4.75736 3.75 3.75 4.75736 3.75 6V7.5M16.5 3.75H18C19.2426 3.75 20.25 4.75736 20.25 6V7.5M20.25 16.5V18C20.25 19.2426 19.2426 20.25 18 20.25H16.5M7.5 20.25H6C4.75736 20.25 3.75 19.2426 3.75 18V16.5M15 12C15 13.6569 13.6569 15 12 15C10.3431 15 9 13.6569 9 12C9 10.3431 10.3431 9 12 9C13.6569 9 15 10.3431 15 12Z",
                },
            },
            Shape::Voicemail => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Volume1 => rsx! {
                path {
                    d: "M15.54 8.46a5 5 0 0 1 0 7.07",
                },
            },
            Shape::Volume2 => rsx! {
                path {
                    d: "M19.07 4.93a10 10 0 0 1 0 14.14M15.54 8.46a5 5 0 0 1 0 7.07",
                },
            },
            Shape::VolumeX => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Volume => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Wallet => rsx! {
                path {
                    d: "M21 12C21 10.7574 19.9926 9.75 18.75 9.75H15C15 11.4069 13.6569 12.75 12 12.75C10.3431 12.75 9 11.4069 9 9.75H5.25C4.00736 9.75 3 10.7574 3 12M21 12V18C21 19.2426 19.9926 20.25 18.75 20.25H5.25C4.00736 20.25 3 19.2426 3 18V12M21 12V9M3 12V9M21 9C21 7.75736 19.9926 6.75 18.75 6.75H5.25C4.00736 6.75 3 7.75736 3 9M21 9V6C21 4.75736 19.9926 3.75 18.75 3.75H5.25C4.00736 3.75 3 4.75736 3 6V9",
                },
            },
            Shape::Watch => rsx! {
                path {
                    d: "M16.51 17.35l-.35 3.83a2 2 0 0 1-2 1.82H9.83a2 2 0 0 1-2-1.82l-.35-3.83m.01-10.7l.35-3.83A2 2 0 0 1 9.83 1h4.35a2 2 0 0 1 2 1.82l.35 3.83",
                },
            },
            Shape::WifiOff => rsx! {
                path {
                    d: "M16.72 11.06A10.94 10.94 0 0 1 19 12.55 M5 12.55a10.94 10.94 0 0 1 5.17-2.39 M10.71 5.05A16 16 0 0 1 22.58 9 M1.42 9a15.91 15.91 0 0 1 4.7-2.88 M8.53 16.11a6 6 0 0 1 6.95 0",
                },
            },
            Shape::Wifi => rsx! {
                path {
                    d: "M5 12.55a11 11 0 0 1 14.08 0 M1.42 9a16 16 0 0 1 21.16 0 M8.53 16.11a6 6 0 0 1 6.95 0",
                },
            },
            Shape::Wind => rsx! {
                path {
                    d: "M9.59 4.59A2 2 0 1 1 11 8H2m10.59 11.41A2 2 0 1 0 14 16H2m15.73-8.27A2.5 2.5 0 1 1 19.5 12H2",
                },
            },
            Shape::WindowShare => rsx! {
                path {
                    d: " M 14.465 10.28 L 21.775 2.98 M 21.775 2.98 L 18.775 2.98 M 21.775 2.98 L 21.775 5.98 M 20.225 9.02 L 20.225 18.77 C 20.225 19.37 19.985 19.94 19.565 20.36 C 19.145 20.78 18.575 21.02 17.975 21.02 L 4.475 21.02 C 3.875 21.02 3.305 20.78 2.885 20.36 C 2.465 19.94 2.225 19.37 2.225 18.77 L 2.225 9.02 M 20.225 7.76 L 20.225 9.02 M 16.925 4.52 L 4.475 4.52 C 3.875 4.52 3.305 4.76 2.885 5.18 C 2.465 5.6 2.225 6.17 2.225 6.77 L 2.225 9.02 M 18.765 9.02 L 20.225 9.02 M 2.225 9.02 L 12.585 9.02 M 4.475 6.78 L 4.475 6.78 C 4.475 6.78 4.475 6.78 4.475 6.78 L 4.475 6.78 Z  M 6.725 6.78 L 6.725 6.78 C 6.725 6.78 6.725 6.78 6.725 6.78 L 6.725 6.78 Z  M 8.975 6.78 L 8.975 6.78 C 8.975 6.78 8.975 6.78 8.975 6.78 L 8.975 6.78 Z ",
                },
            },
            Shape::Window => rsx! {
                path {
                    d: "M3 8.25V18C3 19.2426 4.00736 20.25 5.25 20.25H18.75C19.9926 20.25 21 19.2426 21 18V8.25M3 8.25V6C3 4.75736 4.00736 3.75 5.25 3.75H18.75C19.9926 3.75 21 4.75736 21 6V8.25M3 8.25H21M5.25 6H5.2575V6.0075H5.25V6ZM7.5 6H7.5075V6.0075H7.5V6ZM9.75 6H9.7575V6.0075H9.75V6Z",
                },
            },
            Shape::WrenchScrewdriver => rsx! {
                path {
                    d: "M11.4194 15.1694L17.25 21C18.2855 22.0355 19.9645 22.0355 21 21C22.0355 19.9645 22.0355 18.2855 21 17.25L15.1233 11.3733M11.4194 15.1694L13.9155 12.1383C14.2315 11.7546 14.6542 11.5132 15.1233 11.3733M11.4194 15.1694L6.76432 20.8219C6.28037 21.4096 5.55897 21.75 4.79768 21.75C3.39064 21.75 2.25 20.6094 2.25 19.2023C2.25 18.441 2.59044 17.7196 3.1781 17.2357L10.0146 11.6056M15.1233 11.3733C15.6727 11.2094 16.2858 11.1848 16.8659 11.2338C16.9925 11.2445 17.1206 11.25 17.25 11.25C19.7353 11.25 21.75 9.23528 21.75 6.75C21.75 6.08973 21.6078 5.46268 21.3523 4.89779L18.0762 8.17397C16.9605 7.91785 16.0823 7.03963 15.8262 5.92397L19.1024 2.64774C18.5375 2.39223 17.9103 2.25 17.25 2.25C14.7647 2.25 12.75 4.26472 12.75 6.75C12.75 6.87938 12.7555 7.00749 12.7662 7.13411C12.8571 8.20956 12.6948 9.39841 11.8617 10.0845L11.7596 10.1686M10.0146 11.6056L5.90901 7.5H4.5L2.25 3.75L3.75 2.25L7.5 4.5V5.90901L11.7596 10.1686M10.0146 11.6056L11.7596 10.1686M18.375 18.375L15.75 15.75M4.86723 19.125H4.87473V19.1325H4.86723V19.125Z",
                },
            },
            Shape::Wrench => rsx! {
                path {
                    d: "M21.75 6.75C21.75 9.23528 19.7353 11.25 17.25 11.25C17.1206 11.25 16.9925 11.2445 16.8659 11.2338C15.7904 11.1429 14.6016 11.3052 13.9155 12.1383L6.76432 20.8219C6.28037 21.4096 5.55897 21.75 4.79769 21.75C3.39064 21.75 2.25 20.6094 2.25 19.2023C2.25 18.441 2.59044 17.7196 3.1781 17.2357L11.8617 10.0845C12.6948 9.39841 12.8571 8.20956 12.7662 7.13411C12.7555 7.00749 12.75 6.87938 12.75 6.75C12.75 4.26472 14.7647 2.25 17.25 2.25C17.9103 2.25 18.5375 2.39223 19.1024 2.64774L15.8262 5.92397C16.0823 7.03963 16.9605 7.91785 18.0762 8.17397L21.3524 4.89779C21.6078 5.46268 21.75 6.08973 21.75 6.75Z M4.86723 19.125H4.87473V19.1325H4.86723V19.125Z",
                },
            },
            Shape::XCircle => rsx! {
                path {
                    d: "",
                },
            },
            Shape::XMark => rsx! {
                path {
                    d: "M6 18L18 6M6 6L18 18",
                },
            },
            Shape::XOctagon => rsx! {
                path {
                    d: "",
                },
            },
            Shape::XSquare => rsx! {
                path {
                    d: "",
                },
            },
            Shape::X => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Youtube => rsx! {
                path {
                    d: "M22.54 6.42a2.78 2.78 0 0 0-1.94-2C18.88 4 12 4 12 4s-6.88 0-8.6.46a2.78 2.78 0 0 0-1.94 2A29 29 0 0 0 1 11.75a29 29 0 0 0 .46 5.33A2.78 2.78 0 0 0 3.4 19c1.72.46 8.6.46 8.6.46s6.88 0 8.6-.46a2.78 2.78 0 0 0 1.94-2 29 29 0 0 0 .46-5.25 29 29 0 0 0-.46-5.33z",
                },
            },
            Shape::ZapOff => rsx! {
                path {
                    d: "",
                },
            },
            Shape::Zap => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ZoomIn => rsx! {
                path {
                    d: "",
                },
            },
            Shape::ZoomOut => rsx! {
                path {
                    d: "",
                },
            },
        }
    }
}
