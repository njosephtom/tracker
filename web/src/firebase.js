import { initializeApp } from 'firebase/app'
import { getAnalytics, isSupported } from 'firebase/analytics'
import { getAuth } from 'firebase/auth'
import { getFirestore } from 'firebase/firestore'

const firebaseConfig = {
  apiKey: 'AIzaSyA3ECe1AN5m1C4XO4LszBc6wj9xRkxmkmA',
  authDomain: 'tracker-b6337.firebaseapp.com',
  projectId: 'tracker-b6337',
  storageBucket: 'tracker-b6337.firebasestorage.app',
  messagingSenderId: '778490026654',
  appId: '1:778490026654:web:f8b347a8c10738ad10398f',
  measurementId: 'G-G7WDBLJ9BD',
}

export const app = initializeApp(firebaseConfig)
export const db = getFirestore(app)
export const auth = getAuth(app)
// ponytail: analytics is optional; only starts where the browser supports it
isSupported().then((ok) => ok && getAnalytics(app))
