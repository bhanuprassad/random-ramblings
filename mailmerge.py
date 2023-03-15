import csv
import smtplib
from getpass import getpass
from mailmerge import MailMerge

# create a MailMerge object
template = "path/to/template.docx" # replace with the path to your template file
document = MailMerge(template)

# get the recipient email list from a CSV file
with open('path/to/recipients.csv') as csvfile:
    reader = csv.reader(csvfile)
    next(reader) # skip the header row
    emails = [row[0] for row in reader]

# prompt for email account credentials
email_account = input("Enter your email address: ")
email_password = getpass("Enter your email password: ")

# set up the SMTP server
smtp_server = "smtp.gmail.com" # replace with your SMTP server
smtp_port = 587 # replace with your SMTP port
smtp_connection = smtplib.SMTP(smtp_server, smtp_port)
smtp_connection.ehlo()
smtp_connection.starttls()
smtp_connection.login(email_account, email_password)

# loop through the email list and send emails
for email in emails:
    try:
        document.merge(recipient=email) # replace with your merge fields
        message = document.write() # get the merged email message
        sender = email_account # replace with your email address
        recipients = [email] # replace with your recipient email address
        smtp_connection.sendmail(sender, recipients, message) # send the email
    except Exception as e:
        print(f"Error sending email to {email}: {e}")

# close the SMTP connection
smtp_connection.quit()
