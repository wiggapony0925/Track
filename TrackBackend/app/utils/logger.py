from colorama import Fore, Style, init
import pyfiglet

# Initialize colorama
init(autoreset=True)


class TrackLogger:
    @staticmethod
    def startup():
        # Print giant ASCII banner
        banner = pyfiglet.figlet_format("TRACK", font="slant")
        print(Fore.CYAN + Style.BRIGHT + banner)
        print(Fore.GREEN + "   >>> TRACK BACKEND ONLINE <<<")
        print(Fore.YELLOW + "   Waiting for iOS connections...\n")

    @staticmethod
    def info(msg):
        print(f"{Fore.GREEN}[INFO]{Style.RESET_ALL} {msg}")

    @staticmethod
    def error(msg):
        print(f"{Fore.RED}[ERROR]{Style.RESET_ALL} {msg}")

    @staticmethod
    def request(method, path, status):
        color = Fore.GREEN if status < 400 else Fore.RED
        print(f"{Fore.BLUE}[REQ]{Style.RESET_ALL} {method} {path} -> {color}{status}{Style.RESET_ALL}")
